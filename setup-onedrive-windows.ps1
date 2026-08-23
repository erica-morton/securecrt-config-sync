[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$PersonalDataPath,

    [Parameter()]
    [string]$RegistryPath = 'HKCU:\Software\VanDyke\SecureCRT',

    [Parameter()]
    [string]$StatePath,

    [Parameter()]
    [switch]$SkipOneDrivePin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$AgentPipe = '\\.\pipe\openssh-ssh-agent'
$testMode = $env:SECURECRT_CONFIG_SYNC_TEST_MODE -eq '1'
$AgentEnvironmentTarget = if ($testMode) { 'Process' } else { 'User' }
$RequiredHelpers = @(
    'setup-onedrive-macos.sh',
    'setup-onedrive-windows.ps1',
    'setup-onedrive-windows.cmd',
    'disconnect-onedrive-macos.sh',
    'disconnect-onedrive-windows.ps1',
    'disconnect-onedrive-windows.cmd'
)
foreach ($helper in $RequiredHelpers) {
    $helperPath = Join-Path $PSScriptRoot $helper
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw @"
Required setup helper is missing: $helperPath
Keep all setup-onedrive-* and disconnect-onedrive-* files together, then retry.
"@
    }
}

function Get-OnePasswordSshAgentIssue {
    $issues = [System.Collections.Generic.List[string]]::new()
    if ($testMode) {
        if ($env:SECURECRT_CONFIG_SYNC_TEST_AGENT_STATE -eq 'missing') {
            $issues.Add('1Password is not running.')
            $issues.Add("The SSH agent pipe is not available: $AgentPipe")
        }
        return $issues
    }

    $onePassword = @(Get-Process -Name '1Password' -ErrorAction SilentlyContinue)
    if ($onePassword.Count -eq 0) {
        $issues.Add('1Password is not running.')
    }

    $windowsAgent = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if ($null -ne $windowsAgent -and $windowsAgent.Status -eq 'Running') {
        $issues.Add('The Windows OpenSSH Authentication Agent service is running.')
    }

    $pipeExists = $false
    try {
        $pipeExists = @([IO.Directory]::GetFiles('\\.\pipe\')) -contains $AgentPipe
    } catch {
        $pipeExists = Test-Path -LiteralPath $AgentPipe
    }
    if (-not $pipeExists) {
        $issues.Add("The SSH agent pipe is not available: $AgentPipe")
    }
    return $issues
}

function Wait-OnePasswordSshAgent {
    while ($true) {
        $issues = @(Get-OnePasswordSshAgentIssue)
        if ($issues.Count -eq 0) {
            Write-Host '1Password SSH agent is ready. Continuing setup.'
            return
        }

        Write-Host ''
        Write-Host '1Password SSH agent setup is required before SecureCRT can be configured.'
        foreach ($issue in $issues) {
            Write-Host "  - $issue"
        }
        Write-Host ''
        Write-Host '1. Install or open 1Password and unlock it.'
        Write-Host '2. Open Settings > Developer and enable "Use the SSH Agent".'
        Write-Host '3. If the Windows OpenSSH Authentication Agent service is running,'
        Write-Host '   stop it and set its startup type to Disabled.'

        $inputIsRedirected = [Console]::IsInputRedirected -or
            ($testMode -and $env:SECURECRT_CONFIG_SYNC_TEST_NONINTERACTIVE -eq '1')
        if ($inputIsRedirected) {
            throw 'Setup is non-interactive, so it cannot wait for 1Password. Run it from a console.'
        }
        $null = Read-Host 'Press Enter after completing those steps to test again (or Ctrl+C to cancel)'
    }
}

Wait-OnePasswordSshAgent

function Send-EnvironmentChangedNotification {
    if ($testMode) {
        return
    }

    if ($null -eq ('SecureCrtConfigSync.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace SecureCrtConfigSync {
    public static class NativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint message,
            UIntPtr wParam,
            string lParam,
            uint flags,
            uint timeout,
            out UIntPtr result);
    }
}
'@
    }

    $result = [UIntPtr]::Zero
    $null = [SecureCrtConfigSync.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001a,
        [UIntPtr]::Zero,
        'Environment',
        0x0002,
        5000,
        [ref]$result
    )
}

function Stop-VanDykeClientsGracefully {
    $runningClients = @(Get-Process -Name SecureCRT, SecureFX -ErrorAction SilentlyContinue)
    if ($runningClients.Count -eq 0) {
        return
    }

    Write-Host 'Asking SecureCRT and SecureFX to close...'
    foreach ($process in $runningClients) {
        $null = $process.CloseMainWindow()
    }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $runningClients = @(
            Get-Process -Name SecureCRT, SecureFX -ErrorAction SilentlyContinue
        )
    } while ($runningClients.Count -gt 0 -and (Get-Date) -lt $deadline)

    if ($runningClients.Count -gt 0) {
        throw @'
SecureCRT or SecureFX did not exit. It may be waiting for confirmation.
Finish closing it, then run setup again. No process was force-terminated.
'@
    }
}

Stop-VanDykeClientsGracefully

function Get-NormalizedDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Folder not found: $Path"
    }
    return (Get-Item -LiteralPath $Path).FullName.TrimEnd([char[]]'\/')
}

function Test-CompleteConfiguration {
    param([Parameter(Mandatory)][string]$Path)

    return (
        (Test-Path -LiteralPath (Join-Path $Path 'Global.ini') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'Sessions') -PathType Container)
    )
}

function Disable-FileBackedSshKey {
    param([Parameter(Mandatory)][string]$ConfigurationPath)

    $ssh2Path = Join-Path $ConfigurationPath 'SSH2.ini'
    if (-not (Test-Path -LiteralPath $ssh2Path -PathType Leaf)) {
        return
    }

    $content = [IO.File]::ReadAllText($ssh2Path)
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $hasTrailingNewline = $content.EndsWith("`n")
    $lines = [Regex]::Split($content, '\r?\n')
    if ($hasTrailingNewline -and $lines.Count -gt 0 -and $lines[-1] -eq '') {
        $lines = $lines[0..($lines.Count - 2)]
    }

    $updatedLines = [System.Collections.Generic.List[string]]::new()
    $changed = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -match '^S:"Identity Filename V2"=') {
            $replacement = 'S:"Identity Filename V2"='
            $updatedLines.Add($replacement)
            $changed = $changed -or $line -ne $replacement
            continue
        }
        if ($line -match '^D:"Add Private Keys To Agent"=') {
            $replacement = 'D:"Add Private Keys To Agent"=00000000'
            $updatedLines.Add($replacement)
            $changed = $changed -or $line -ne $replacement
            continue
        }
        if ($line -match '^Z:"Agent Keys To Load"=([0-9A-Fa-f]{8})$') {
            $keyCount = [Convert]::ToInt32($Matches[1], 16)
            if ($index + $keyCount -ge $lines.Count) {
                throw "The SSH agent key list is malformed: $ssh2Path"
            }
            $replacement = 'Z:"Agent Keys To Load"=00000000'
            $updatedLines.Add($replacement)
            $changed = $changed -or $line -ne $replacement -or $keyCount -gt 0
            $index += $keyCount
            continue
        }
        $updatedLines.Add($line)
    }

    if (-not $changed) {
        return
    }

    $updatedContent = $updatedLines -join $newline
    if ($hasTrailingNewline) {
        $updatedContent += $newline
    }
    $temporaryPath = "$ssh2Path.securecrt-config-sync.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporaryPath, $updatedContent, [Text.UTF8Encoding]::new($true))
        Move-Item -LiteralPath $temporaryPath -Destination $ssh2Path -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-OptionalRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }
    $property = $item.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Save-SetupState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $State | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ShareableConfiguration {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-CompleteConfiguration -Path $Path)) {
        throw "The configuration is incomplete: $Path"
    }

    $candidateSessionFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $Path 'Sessions') -File -Filter '*.ini' -Recurse
    )
    $sensitiveFiles = @(
        $candidateSessionFiles |
            Select-String -Pattern @(
                'S:"[^"]*(?:Password|Passphrase)[^"]*"=.+$',
                'D:"Session Password Saved"=00000001$'
            ) |
            ForEach-Object Path |
            Sort-Object -Unique
    )
    if ($sensitiveFiles.Count -gt 0) {
        $fileList = $sensitiveFiles -join "`n  "
        throw @"
Refusing to share a configuration that may contain saved credentials.
Move credentials into SecureCRT's Personal Data folder, then retry. Files:
  $fileList
"@
    }
}

function Copy-ConfigurationAtomically {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Assert-ShareableConfiguration -Path $Source
    $destinationParent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    $stagingPath = Join-Path $destinationParent ".Config.migration.$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $stagingPath | Out-Null
    try {
        Get-ChildItem -LiteralPath $Source -Force |
            Copy-Item -Destination $stagingPath -Recurse -Force
        Disable-FileBackedSshKey -ConfigurationPath $stagingPath
        Assert-ShareableConfiguration -Path $stagingPath
        Move-Item -LiteralPath $stagingPath -Destination $Destination
    } catch {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    Write-Host 'Migrated the existing SecureCRT configuration:'
    Write-Host "  From: $Source"
    Write-Host "  To:   $Destination"
}

function Publish-SetupPackage {
    param([Parameter(Mandatory)][string]$SharedConfigurationPath)

    $secureCrtRoot = Split-Path -Parent $SharedConfigurationPath
    foreach ($helper in $RequiredHelpers) {
        $sourcePath = (Get-Item -LiteralPath (Join-Path $PSScriptRoot $helper)).FullName
        $targetPath = Join-Path $secureCrtRoot $helper
        $samePath = $sourcePath.Equals(
            [IO.Path]::GetFullPath($targetPath),
            [StringComparison]::OrdinalIgnoreCase
        )
        if (-not $samePath) {
            Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
        }
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash) {
            throw "Setup helper publication failed: $targetPath"
        }
    }
}

function Set-PersonalSessionUsername {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Username
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $usernameLine = 'S:"Username"=' + $Username

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $content = [IO.File]::ReadAllText($Path)
        $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
        $hasTrailingNewline = $content.EndsWith("`n")
        $lines = [Regex]::Split($content, '\r?\n')
        if ($hasTrailingNewline -and $lines.Count -gt 0 -and $lines[-1] -eq '') {
            $lines = $lines[0..($lines.Count - 2)]
        }

        $updatedLines = [System.Collections.Generic.List[string]]::new()
        $found = $false
        foreach ($line in $lines) {
            if ($line -match '^S:"Username"=') {
                if (-not $found) {
                    $updatedLines.Add($usernameLine)
                    $found = $true
                }
                continue
            }
            $updatedLines.Add($line)
        }
        if (-not $found) {
            $updatedLines.Add($usernameLine)
        }
        $content = $updatedLines -join $newline
        if ($hasTrailingNewline) {
            $content += $newline
        }
    } else {
        $content = "D:`"Session Password Saved`"=00000000`r`n$usernameLine`r`n"
    }

    [IO.File]::WriteAllText($Path, $content, [Text.UTF8Encoding]::new($true))
}

function Sync-SessionUsername {
    param(
        [Parameter(Mandatory)][IO.FileInfo[]]$SessionFiles,
        [Parameter(Mandatory)][string]$SharedSessionsPath,
        [Parameter(Mandatory)][string]$PersonalDataPath
    )

    $synced = 0
    $personalSessionsPath = Join-Path $PersonalDataPath 'Sessions'
    foreach ($sessionFile in $SessionFiles) {
        if ($sessionFile.Name -in '__FolderData__.ini', 'Default.ini') {
            continue
        }

        $username = $null
        foreach ($line in [IO.File]::ReadAllLines($sessionFile.FullName)) {
            if ($line -match '^S:"Username"=(.*)$') {
                $username = $Matches[1]
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($username)) {
            continue
        }

        $relativePath = $sessionFile.FullName.Substring($SharedSessionsPath.Length).TrimStart([char[]]'\/')
        $personalSession = Join-Path $personalSessionsPath $relativePath
        Set-PersonalSessionUsername -Path $personalSession -Username $username
        $synced++
    }
    return $synced
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $candidates = [System.Collections.Generic.List[string]]::new()

    # When run from OneDrive\SecureCRT, Config is next to this script.
    $candidates.Add((Join-Path $PSScriptRoot 'Config'))

    foreach ($variableName in 'OneDriveConsumer', 'OneDrive', 'OneDriveCommercial') {
        $oneDriveRoot = [Environment]::GetEnvironmentVariable($variableName, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($oneDriveRoot)) {
            $candidates.Add((Join-Path $oneDriveRoot 'SecureCRT\Config'))
        }
    }

    $validCandidates = @(
        $candidates |
            Select-Object -Unique |
            Where-Object { Test-CompleteConfiguration -Path $_ }
    )

    if ($validCandidates.Count -gt 1) {
        $found = $validCandidates -join "`n  "
        throw "More than one SecureCRT configuration was found. Re-run with -ConfigPath:`n  $found"
    }

    if ($validCandidates.Count -eq 1) {
        $ConfigPath = $validCandidates[0]
    } else {
        $oneDriveRoots = @(
            @(
                foreach ($variableName in 'OneDriveConsumer', 'OneDrive', 'OneDriveCommercial') {
                    $oneDriveRoot = [Environment]::GetEnvironmentVariable($variableName, 'Process')
                    if (-not [string]::IsNullOrWhiteSpace($oneDriveRoot) -and
                        (Test-Path -LiteralPath $oneDriveRoot -PathType Container)) {
                        (Get-Item -LiteralPath $oneDriveRoot).FullName
                    }
                }
            ) | Select-Object -Unique
        )
        if ($oneDriveRoots.Count -eq 0) {
            throw 'Could not find a OneDrive folder. Re-run with -ConfigPath.'
        }
        if ($oneDriveRoots.Count -gt 1) {
            $found = $oneDriveRoots -join "`n  "
            throw @"
More than one OneDrive folder was found. Re-run with -ConfigPath for the new
shared Config folder:
  $found
"@
        }
        $ConfigPath = Join-Path $oneDriveRoots[0] 'SecureCRT\Config'
    }
}

$ConfigPath = [IO.Path]::GetFullPath($ConfigPath).TrimEnd([char[]]'\/')
if (-not (Test-CompleteConfiguration -Path $ConfigPath)) {
    if (Test-Path -LiteralPath $ConfigPath) {
        throw @"
The target configuration exists but is incomplete: $ConfigPath
Move or repair that folder, then retry; setup will not overwrite it.
"@
    }

    $configuredSource = Get-OptionalRegistryValue -Path $RegistryPath -Name 'Config Path'
    $migrationSource = $null
    if (-not [string]::IsNullOrWhiteSpace($configuredSource) -and
        (Test-CompleteConfiguration -Path $configuredSource)) {
        $migrationSource = Get-NormalizedDirectory -Path $configuredSource
    } elseif (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $defaultSources = @(
            (Join-Path $env:APPDATA 'VanDyke\Config'),
            (Join-Path $env:APPDATA 'VanDyke\SecureCRT\Config')
        )
        $validDefaultSources = @(
            $defaultSources |
                Select-Object -Unique |
                Where-Object { Test-CompleteConfiguration -Path $_ }
        )
        if ($validDefaultSources.Count -gt 1) {
            $found = $validDefaultSources -join "`n  "
            throw "More than one local SecureCRT configuration was found:`n  $found"
        }
        if ($validDefaultSources.Count -eq 1) {
            $migrationSource = Get-NormalizedDirectory -Path $validDefaultSources[0]
        }
    }
    if ([string]::IsNullOrWhiteSpace($migrationSource)) {
        throw @"
The shared configuration does not exist yet, and no existing local SecureCRT
configuration was found to migrate. Expected target: $ConfigPath
"@
    }

    Copy-ConfigurationAtomically -Source $migrationSource -Destination $ConfigPath
}

$ConfigPath = Get-NormalizedDirectory -Path $ConfigPath
$globalIni = Join-Path $ConfigPath 'Global.ini'
$sessionsPath = Join-Path $ConfigPath 'Sessions'
Assert-ShareableConfiguration -Path $ConfigPath
Disable-FileBackedSshKey -ConfigurationPath $ConfigPath

$sessionFiles = @(
    Get-ChildItem -LiteralPath $sessionsPath -File -Filter '*.ini' -Recurse
)

Publish-SetupPackage -SharedConfigurationPath $ConfigPath

if (-not $SkipOneDrivePin) {
    # Mark the whole SecureCRT tree as Always Available. This is the scriptable
    # equivalent of OneDrive's "Always keep on this device" action.
    $secureCrtRoot = Split-Path -Parent $ConfigPath
    & attrib.exe +p $secureCrtRoot
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not pin $secureCrtRoot for offline use. Setup will continue."
    }
}

# Reading the synced files forces OneDrive placeholders needed for validation
# to hydrate before SecureCRT starts using the tree.
$null = Get-Content -LiteralPath $globalIni -TotalCount 1
$sessionCount = @(
    $sessionFiles |
        Where-Object Name -notin '__FolderData__.ini', 'Default.ini'
).Count

if ([string]::IsNullOrWhiteSpace($PersonalDataPath)) {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw 'APPDATA is not set. Re-run with -PersonalDataPath.'
    }
    $PersonalDataPath = Join-Path $env:APPDATA 'VanDyke\SecureCRT\Config.personal'
}
New-Item -ItemType Directory -Path $PersonalDataPath -Force | Out-Null
$PersonalDataPath = Get-NormalizedDirectory -Path $PersonalDataPath
$syncedUsernameCount = Sync-SessionUsername `
    -SessionFiles $sessionFiles `
    -SharedSessionsPath $sessionsPath `
    -PersonalDataPath $PersonalDataPath

$oldAgentPipe = [Environment]::GetEnvironmentVariable(
    'VANDYKE_SSH_AUTH_SOCK',
    $AgentEnvironmentTarget
)

$oldConfigPath = $null
$oldPersonalDataPath = $null
$oldStorePersonalDataSeparately = $null
if (Test-Path -LiteralPath $registryPath) {
    try {
        $oldConfigPath = Get-ItemPropertyValue -LiteralPath $registryPath `
            -Name 'Config Path' -ErrorAction Stop
    } catch [System.Management.Automation.PSArgumentException] {
        $oldConfigPath = $null
    }
    try {
        $oldPersonalDataPath = Get-ItemPropertyValue -LiteralPath $registryPath `
            -Name 'Personal Data Path' -ErrorAction Stop
    } catch [System.Management.Automation.PSArgumentException] {
        $oldPersonalDataPath = $null
    }
    $oldStorePersonalDataSeparately = Get-OptionalRegistryValue `
        -Path $registryPath -Name 'Store Personal Data Separately'
}

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA is not set, so setup state cannot be stored.'
}
$backupDirectory = Join-Path $env:LOCALAPPDATA 'VanDyke\SecureCRT-Setup-Backups'
if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $env:LOCALAPPDATA `
        'VanDyke\SecureCRT-Setup-State\onedrive-sync.json'
}
$StatePath = [IO.Path]::GetFullPath($StatePath)

$setupState = $null
if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
    $setupState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($setupState.Version -ne 1) {
        throw "Unsupported SecureCRT setup state version in $StatePath"
    }
}

if ($null -eq $setupState -or -not $setupState.Active) {
    $beforeConfigPath = $oldConfigPath
    $beforePersonalDataPath = $oldPersonalDataPath
    $beforeStorePersonalDataSeparately = $oldStorePersonalDataSeparately
    $beforeAgentPipe = $oldAgentPipe

    $looksLikeLegacyInstall = $oldConfigPath -eq $ConfigPath -and
        $oldPersonalDataPath -eq $PersonalDataPath -and
        $oldStorePersonalDataSeparately -eq 1 -and
        $oldAgentPipe -eq $AgentPipe
    if ($looksLikeLegacyInstall -and (Test-Path -LiteralPath $backupDirectory)) {
        $legacyState = $null
        $newestMatchingLegacyState = $null
        foreach ($legacyBackup in @(
            Get-ChildItem -LiteralPath $backupDirectory `
                -Filter 'configuration-paths-*.json' -File |
                Sort-Object LastWriteTimeUtc -Descending
        )) {
            $candidateLegacyState = Get-Content -LiteralPath $legacyBackup.FullName `
                -Raw | ConvertFrom-Json
            if ($candidateLegacyState.RegistryPath -eq $registryPath) {
                if ($null -eq $newestMatchingLegacyState) {
                    $newestMatchingLegacyState = $candidateLegacyState
                }
                if ($candidateLegacyState.ConfigPath -ne $ConfigPath) {
                    $legacyState = $candidateLegacyState
                    break
                }
            }
        }
        if ($null -eq $legacyState) {
            $legacyState = $newestMatchingLegacyState
        }
        if ($null -ne $legacyState) {
            $beforeConfigPath = $legacyState.ConfigPath
            $beforePersonalDataPath = $legacyState.PersonalDataPath
            $storeProperty = $legacyState.PSObject.Properties[
                'StorePersonalDataSeparately'
            ]
            $beforeStorePersonalDataSeparately = if ($null -eq $storeProperty) {
                $null
            } else {
                $storeProperty.Value
            }
            $beforeAgentPipe = $legacyState.VanDykeSshAuthSock
        }
    }
    if ($looksLikeLegacyInstall -and $beforeConfigPath -eq $ConfigPath -and
        -not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        foreach ($localCandidate in @(
            (Join-Path $env:APPDATA 'VanDyke\SecureCRT\Config'),
            (Join-Path $env:APPDATA 'VanDyke\Config')
        )) {
            if ((Test-CompleteConfiguration -Path $localCandidate) -and
                $localCandidate -ne $ConfigPath) {
                $beforeConfigPath = (Get-Item -LiteralPath $localCandidate).FullName
                $beforePersonalDataPath = $null
                $beforeStorePersonalDataSeparately = $null
                $beforeAgentPipe = $null
                break
            }
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $setupState = [ordered]@{
        Version = 1
        Active = $true
        CreatedAt = $now
        UpdatedAt = $now
        RegistryPath = $registryPath
        AgentEnvironmentTarget = $AgentEnvironmentTarget
        ConfigPathBeforePresent = $null -ne $beforeConfigPath
        ConfigPathBefore = $beforeConfigPath
        ConfigPathInstalled = $ConfigPath
        PersonalDataPathBeforePresent = $null -ne $beforePersonalDataPath
        PersonalDataPathBefore = $beforePersonalDataPath
        PersonalDataPathInstalled = $PersonalDataPath
        StorePersonalDataSeparatelyBeforePresent = `
            $null -ne $beforeStorePersonalDataSeparately
        StorePersonalDataSeparatelyBefore = $beforeStorePersonalDataSeparately
        StorePersonalDataSeparatelyInstalled = 1
        VanDykeSshAuthSockBeforePresent = $null -ne $beforeAgentPipe
        VanDykeSshAuthSockBefore = $beforeAgentPipe
        VanDykeSshAuthSockInstalled = $AgentPipe
    }
} else {
    $setupState.Active = $true
    $setupState.UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
    $setupState.RegistryPath = $registryPath
    $setupState.AgentEnvironmentTarget = $AgentEnvironmentTarget
    $setupState.ConfigPathInstalled = $ConfigPath
    $setupState.PersonalDataPathInstalled = $PersonalDataPath
    $setupState.StorePersonalDataSeparatelyInstalled = 1
    $setupState.VanDykeSshAuthSockInstalled = $AgentPipe
}
Save-SetupState -Path $StatePath -State $setupState

if ($oldConfigPath -ne $ConfigPath -or
    $oldPersonalDataPath -ne $PersonalDataPath -or
    $oldStorePersonalDataSeparately -ne 1 -or
    $oldAgentPipe -ne $AgentPipe) {
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $backupPath = Join-Path $backupDirectory "configuration-paths-$timestamp.json"
    [ordered]@{
        RegistryPath = $registryPath
        ConfigPath = $oldConfigPath
        PersonalDataPath = $oldPersonalDataPath
        StorePersonalDataSeparately = $oldStorePersonalDataSeparately
        VanDykeSshAuthSock = $oldAgentPipe
    } | ConvertTo-Json | Set-Content -LiteralPath $backupPath -Encoding UTF8
    Write-Host "Backed up the previous path settings to $backupPath"
}

if (-not (Test-Path -LiteralPath $registryPath)) {
    New-Item -Path $registryPath | Out-Null
}
New-ItemProperty -LiteralPath $registryPath -Name 'Config Path' -PropertyType String `
    -Value $ConfigPath -Force | Out-Null
New-ItemProperty -LiteralPath $registryPath -Name 'Personal Data Path' -PropertyType String `
    -Value $PersonalDataPath -Force | Out-Null
New-ItemProperty -LiteralPath $registryPath -Name 'Store Personal Data Separately' `
    -PropertyType DWord -Value 1 -Force | Out-Null

$configuredConfig = Get-ItemPropertyValue -LiteralPath $registryPath -Name 'Config Path'
$configuredPersonal = Get-ItemPropertyValue -LiteralPath $registryPath -Name 'Personal Data Path'
$configuredStorePersonalDataSeparately = Get-ItemPropertyValue -LiteralPath $registryPath `
    -Name 'Store Personal Data Separately'
if ($configuredConfig -ne $ConfigPath -or
    $configuredPersonal -ne $PersonalDataPath -or
    $configuredStorePersonalDataSeparately -ne 1) {
    throw 'SecureCRT registry verification failed.'
}

[Environment]::SetEnvironmentVariable(
    'VANDYKE_SSH_AUTH_SOCK',
    $AgentPipe,
    $AgentEnvironmentTarget
)
$configuredAgentPipe = [Environment]::GetEnvironmentVariable(
    'VANDYKE_SSH_AUTH_SOCK',
    $AgentEnvironmentTarget
)
if ($configuredAgentPipe -ne $AgentPipe) {
    throw 'SecureCRT external SSH agent configuration failed.'
}
if (-not $testMode) {
    $env:VANDYKE_SSH_AUTH_SOCK = $AgentPipe
    Send-EnvironmentChangedNotification
}
$sshAgentStatus = $AgentPipe

Write-Host ''
Write-Host 'SecureCRT OneDrive setup is complete.'
Write-Host "  Shared configuration: $ConfigPath"
Write-Host "  Local personal data:  $PersonalDataPath"
Write-Host "  Saved sessions:        $sessionCount"
Write-Host "  Synced usernames:      $syncedUsernameCount"
Write-Host "  External SSH agent:    $sshAgentStatus"
Write-Host "  Disconnect state:      $StatePath"
Write-Host ''
Write-Host 'Launch SecureCRT normally. No administrator access or Git checkout is required.'
