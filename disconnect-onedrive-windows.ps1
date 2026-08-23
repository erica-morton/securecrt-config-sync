[CmdletBinding()]
param(
    [Parameter()]
    [string]$StatePath,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testMode = $env:SECURECRT_CONFIG_SYNC_TEST_MODE -eq '1'

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

    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $State | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Stop-VanDykeClientGracefully {
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
Finish closing it, then run disconnect again. No process was force-terminated.
'@
    }
}

function Send-EnvironmentChangedNotification {
    if ($testMode) {
        return
    }

    if ($null -eq ('SecureCrtConfigSync.DisconnectNativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace SecureCrtConfigSync {
    public static class DisconnectNativeMethods {
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
    $null = [SecureCrtConfigSync.DisconnectNativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001a,
        [UIntPtr]::Zero,
        'Environment',
        0x0002,
        5000,
        [ref]$result
    )
}

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is not set. Re-run with -StatePath.'
    }
    $StatePath = Join-Path $env:LOCALAPPDATA `
        'VanDyke\SecureCRT-Setup-State\onedrive-sync.json'
}
$StatePath = [IO.Path]::GetFullPath($StatePath)
if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    throw @"
No SecureCRT setup state was found at $StatePath.
Run the current setup helper once to create rollback state, then retry.
No settings were changed.
"@
}

$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
if ($state.Version -ne 1) {
    throw "Unsupported SecureCRT setup state version in $StatePath"
}
if (-not $state.Active) {
    Write-Host 'This computer is already disconnected from SecureCRT OneDrive setup.'
    Write-Host "Personal Data was retained at $($state.PersonalDataPathInstalled)"
    exit 0
}

if (-not $DryRun) {
    Stop-VanDykeClientGracefully
}

$registryPath = [string]$state.RegistryPath
$configCurrent = Get-OptionalRegistryValue -Path $registryPath -Name 'Config Path'
$personalCurrent = Get-OptionalRegistryValue -Path $registryPath -Name 'Personal Data Path'
$storeCurrent = Get-OptionalRegistryValue `
    -Path $registryPath -Name 'Store Personal Data Separately'

$changes = [System.Collections.Generic.List[string]]::new()
$skips = [System.Collections.Generic.List[string]]::new()

if ($configCurrent -eq $state.ConfigPathInstalled) {
    $changes.Add('restore the previous SecureCRT configuration path')
    if (-not $DryRun) {
        if ($state.ConfigPathBeforePresent) {
            New-Item -Path $registryPath -Force | Out-Null
            New-ItemProperty -LiteralPath $registryPath -Name 'Config Path' `
                -PropertyType String -Value ([string]$state.ConfigPathBefore) `
                -Force | Out-Null
        } else {
            Remove-ItemProperty -LiteralPath $registryPath -Name 'Config Path' `
                -ErrorAction SilentlyContinue
        }
    }
} else {
    $skips.Add('configuration path changed after setup')
}

if ($personalCurrent -eq $state.PersonalDataPathInstalled) {
    $changes.Add('restore the previous Personal Data path')
    if (-not $DryRun) {
        if ($state.PersonalDataPathBeforePresent) {
            New-Item -Path $registryPath -Force | Out-Null
            New-ItemProperty -LiteralPath $registryPath -Name 'Personal Data Path' `
                -PropertyType String -Value ([string]$state.PersonalDataPathBefore) `
                -Force | Out-Null
        } else {
            Remove-ItemProperty -LiteralPath $registryPath -Name 'Personal Data Path' `
                -ErrorAction SilentlyContinue
        }
    }
} else {
    $skips.Add('Personal Data path changed after setup')
}

if ($storeCurrent -eq $state.StorePersonalDataSeparatelyInstalled) {
    $changes.Add('restore the previous Personal Data separation setting')
    if (-not $DryRun) {
        if ($state.StorePersonalDataSeparatelyBeforePresent) {
            New-Item -Path $registryPath -Force | Out-Null
            New-ItemProperty -LiteralPath $registryPath `
                -Name 'Store Personal Data Separately' -PropertyType DWord `
                -Value ([int]$state.StorePersonalDataSeparatelyBefore) `
                -Force | Out-Null
        } else {
            Remove-ItemProperty -LiteralPath $registryPath `
                -Name 'Store Personal Data Separately' -ErrorAction SilentlyContinue
        }
    }
} else {
    $skips.Add('Personal Data separation setting changed after setup')
}

$agentTarget = [EnvironmentVariableTarget]$state.AgentEnvironmentTarget
$agentCurrent = [Environment]::GetEnvironmentVariable(
    'VANDYKE_SSH_AUTH_SOCK',
    $agentTarget
)
if ($agentCurrent -eq $state.VanDykeSshAuthSockInstalled) {
    $changes.Add('restore the previous SecureCRT external-agent environment value')
    if (-not $DryRun) {
        $agentBefore = if ($state.VanDykeSshAuthSockBeforePresent) {
            [string]$state.VanDykeSshAuthSockBefore
        } else {
            $null
        }
        [Environment]::SetEnvironmentVariable(
            'VANDYKE_SSH_AUTH_SOCK',
            $agentBefore,
            $agentTarget
        )
        if (-not $testMode) {
            $env:VANDYKE_SSH_AUTH_SOCK = $agentBefore
            Send-EnvironmentChangedNotification
        }
    }
} else {
    $skips.Add('external-agent environment value changed after setup')
}

Write-Host ''
$heading = if ($DryRun) { 'SecureCRT disconnect dry run:' } else { 'SecureCRT disconnected:' }
Write-Host $heading
foreach ($change in $changes) {
    Write-Host "  - $change"
}
foreach ($skip in $skips) {
    Write-Host "  - left unchanged: $skip"
}
Write-Host '  - retained the OneDrive configuration'
Write-Host "  - retained Personal Data at $($state.PersonalDataPathInstalled)"

if (-not $DryRun) {
    $state.Active = $false
    $disconnectedAt = (Get-Date).ToUniversalTime().ToString('o')
    $state | Add-Member -NotePropertyName DisconnectedAt `
        -NotePropertyValue $disconnectedAt -Force
    $state.UpdatedAt = $disconnectedAt
    Save-SetupState -Path $StatePath -State $state
}
