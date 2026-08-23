[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$PersonalDataPath,

    [Parameter()]
    [string]$RegistryPath = 'HKCU:\Software\VanDyke\SecureCRT',

    [Parameter()]
    [switch]$SkipOneDrivePin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_ 'Global.ini') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $_ 'Sessions') -PathType Container)
            }
    )

    if ($validCandidates.Count -eq 0) {
        $tried = ($candidates | Select-Object -Unique) -join "`n  "
        throw "Could not find the synced SecureCRT configuration. Tried:`n  $tried"
    }
    if ($validCandidates.Count -gt 1) {
        $found = $validCandidates -join "`n  "
        throw "More than one SecureCRT configuration was found. Re-run with -ConfigPath:`n  $found"
    }

    $ConfigPath = $validCandidates[0]
}

$ConfigPath = Get-NormalizedDirectory -Path $ConfigPath
$globalIni = Join-Path $ConfigPath 'Global.ini'
$sessionsPath = Join-Path $ConfigPath 'Sessions'

if (-not (Test-Path -LiteralPath $globalIni -PathType Leaf)) {
    throw "Global.ini not found in the configuration folder: $ConfigPath"
}
if (-not (Test-Path -LiteralPath $sessionsPath -PathType Container)) {
    throw "SecureCRT Sessions folder not found: $sessionsPath"
}

$sessionFiles = @(
    Get-ChildItem -LiteralPath $sessionsPath -File -Filter '*.ini' -Recurse
)
$sensitiveFiles = @(
    $sessionFiles |
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

$oldConfigPath = $null
$oldPersonalDataPath = $null
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
}

if ($oldConfigPath -ne $ConfigPath -or $oldPersonalDataPath -ne $PersonalDataPath) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is not set, so the previous settings cannot be backed up.'
    }
    $backupDirectory = Join-Path $env:LOCALAPPDATA 'VanDyke\SecureCRT-Setup-Backups'
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $backupPath = Join-Path $backupDirectory "configuration-paths-$timestamp.json"
    [ordered]@{
        RegistryPath = $registryPath
        ConfigPath = $oldConfigPath
        PersonalDataPath = $oldPersonalDataPath
    } | ConvertTo-Json | Set-Content -LiteralPath $backupPath -Encoding UTF8
    Write-Host "Backed up the previous path settings to $backupPath"
}

New-Item -Path $registryPath -Force | Out-Null
New-ItemProperty -LiteralPath $registryPath -Name 'Config Path' -PropertyType String `
    -Value $ConfigPath -Force | Out-Null
New-ItemProperty -LiteralPath $registryPath -Name 'Personal Data Path' -PropertyType String `
    -Value $PersonalDataPath -Force | Out-Null

$configuredConfig = Get-ItemPropertyValue -LiteralPath $registryPath -Name 'Config Path'
$configuredPersonal = Get-ItemPropertyValue -LiteralPath $registryPath -Name 'Personal Data Path'
if ($configuredConfig -ne $ConfigPath -or $configuredPersonal -ne $PersonalDataPath) {
    throw 'SecureCRT registry verification failed.'
}

Write-Host ''
Write-Host 'SecureCRT OneDrive setup is complete.'
Write-Host "  Shared configuration: $ConfigPath"
Write-Host "  Local personal data:  $PersonalDataPath"
Write-Host "  Saved sessions:        $sessionCount"
Write-Host ''
Write-Host 'Launch SecureCRT normally. No administrator access or Git checkout is required.'
