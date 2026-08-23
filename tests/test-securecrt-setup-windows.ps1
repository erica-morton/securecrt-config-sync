[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$installer = Join-Path $repoRoot 'setup-onedrive-windows.ps1'
$wrapper = Join-Path $repoRoot 'setup-onedrive-windows.cmd'
$testId = [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "securecrt-setup-$testId"
$registryRoot = 'HKCU:\Software\SecureCRTConfigSyncTests'
$registryPath = Join-Path $registryRoot $testId
$wrapperRegistryPath = Join-Path $registryRoot "$testId-wrapper"
$oldLocalAppData = $env:LOCALAPPDATA
$oldCI = $env:CI
$oldOneDriveConsumer = $env:OneDriveConsumer
$oldOneDrive = $env:OneDrive
$oldOneDriveCommercial = $env:OneDriveCommercial

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Label
    )
    if ($Expected -ne $Actual) {
        throw "Expected $Label to be '$Expected', got '$Actual'."
    }
}

function New-TestConfiguration {
    param([Parameter(Mandatory)][string]$Root)

    $config = Join-Path $Root 'SecureCRT\Config'
    $sessionGroup = Join-Path $config 'Sessions\Example Group'
    New-Item -ItemType Directory -Path (Join-Path $sessionGroup 'VMs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $config 'Global.ini') -Value 'test global configuration'
    Set-Content -LiteralPath (Join-Path $sessionGroup '__FolderData__.ini') -Value 'folder metadata'
    Set-Content -LiteralPath (Join-Path $sessionGroup 'host-one.ini') -Value 'host one'
    Set-Content -LiteralPath (Join-Path $sessionGroup 'VMs\host-two.ini') -Value 'host two'
    return $config
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:LOCALAPPDATA = Join-Path $testRoot 'LocalAppData'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null

    $configPath = New-TestConfiguration -Root (Join-Path $testRoot 'OneDrive')
    $personalPath = Join-Path $testRoot 'Personal\Config.personal'

    New-Item -Path $registryPath -Force | Out-Null
    New-ItemProperty -LiteralPath $registryPath -Name 'Config Path' `
        -PropertyType String -Value 'C:\previous\config' -Force | Out-Null
    New-ItemProperty -LiteralPath $registryPath -Name 'Personal Data Path' `
        -PropertyType String -Value 'C:\previous\personal' -Force | Out-Null

    $firstOutput = & $installer `
        -ConfigPath $configPath `
        -PersonalDataPath $personalPath `
        -RegistryPath $registryPath `
        -SkipOneDrivePin 6>&1 | Out-String

    Assert-Equal $configPath `
        (Get-ItemPropertyValue -LiteralPath $registryPath -Name 'Config Path') `
        'Config Path'
    Assert-Equal $personalPath `
        (Get-ItemPropertyValue -LiteralPath $registryPath -Name 'Personal Data Path') `
        'Personal Data Path'
    if (-not (Test-Path -LiteralPath $personalPath -PathType Container)) {
        throw 'The Personal Data folder was not created.'
    }
    if ($firstOutput -notmatch 'Saved sessions:\s+2') {
        throw "The installer reported the wrong session count:`n$firstOutput"
    }

    $backupDirectory = Join-Path $env:LOCALAPPDATA 'VanDyke\SecureCRT-Setup-Backups'
    $backups = @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' -File)
    Assert-Equal 1 $backups.Count 'first-run backup count'
    $backup = Get-Content -LiteralPath $backups[0].FullName -Raw | ConvertFrom-Json
    Assert-Equal 'C:\previous\config' $backup.ConfigPath 'backed-up Config Path'
    Assert-Equal 'C:\previous\personal' $backup.PersonalDataPath 'backed-up Personal Data Path'

    & $installer `
        -ConfigPath $configPath `
        -PersonalDataPath $personalPath `
        -RegistryPath $registryPath `
        -SkipOneDrivePin | Out-Null
    $backups = @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' -File)
    Assert-Equal 1 $backups.Count 'second-run backup count'

    $wrapperPersonalPath = Join-Path $testRoot 'WrapperPersonal\Config.personal'
    $env:CI = 'true'
    & $wrapper `
        -ConfigPath $configPath `
        -PersonalDataPath $wrapperPersonalPath `
        -RegistryPath $wrapperRegistryPath `
        -SkipOneDrivePin
    if ($LASTEXITCODE -ne 0) {
        throw "The CMD wrapper failed with exit code $LASTEXITCODE."
    }
    Assert-Equal $configPath `
        (Get-ItemPropertyValue -LiteralPath $wrapperRegistryPath -Name 'Config Path') `
        'wrapper Config Path'

    $oneDriveA = Join-Path $testRoot 'OneDriveA'
    $oneDriveB = Join-Path $testRoot 'OneDriveB'
    $null = New-TestConfiguration -Root $oneDriveA
    $null = New-TestConfiguration -Root $oneDriveB
    $env:OneDriveConsumer = $oneDriveA
    $env:OneDrive = $oneDriveB
    $env:OneDriveCommercial = $null
    try {
        & $installer `
            -PersonalDataPath $personalPath `
            -RegistryPath $registryPath `
            -SkipOneDrivePin | Out-Null
        throw 'Expected ambiguous OneDrive discovery to fail.'
    } catch {
        if ($_.Exception.Message -notmatch 'More than one SecureCRT configuration') {
            throw
        }
    }

    try {
        & $installer `
            -ConfigPath (Join-Path $testRoot 'missing') `
            -PersonalDataPath $personalPath `
            -RegistryPath $registryPath `
            -SkipOneDrivePin | Out-Null
        throw 'Expected a missing configuration to fail.'
    } catch {
        if ($_.Exception.Message -notmatch 'Folder not found') {
            throw
        }
    }

    $unsafeSession = Join-Path $configPath 'Sessions\Example Group\unsafe.ini'
    Set-Content -LiteralPath $unsafeSession -Value 'S:"Password V2"=do-not-sync'
    try {
        & $installer `
            -ConfigPath $configPath `
            -PersonalDataPath $personalPath `
            -RegistryPath $registryPath `
            -SkipOneDrivePin | Out-Null
        throw 'Expected a configuration containing saved credentials to fail.'
    } catch {
        if ($_.Exception.Message -notmatch 'may contain saved credentials') {
            throw
        }
    } finally {
        Remove-Item -LiteralPath $unsafeSession -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Windows SecureCRT setup integration test passed.'
} finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    $env:CI = $oldCI
    $env:OneDriveConsumer = $oldOneDriveConsumer
    $env:OneDrive = $oldOneDrive
    $env:OneDriveCommercial = $oldOneDriveCommercial
    Remove-Item -LiteralPath $registryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $wrapperRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
