[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$installer = Join-Path $repoRoot 'setup-onedrive-windows.ps1'
$wrapper = Join-Path $repoRoot 'setup-onedrive-windows.cmd'
$disconnect = Join-Path $repoRoot 'disconnect-onedrive-windows.ps1'
$disconnectWrapper = Join-Path $repoRoot 'disconnect-onedrive-windows.cmd'
$testId = [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "securecrt-setup-$testId"
$registryRoot = 'HKCU:\Software\SecureCRTConfigSyncTests'
$registryPath = Join-Path $registryRoot $testId
$wrapperRegistryPath = Join-Path $registryRoot "$testId-wrapper"
$migrationRegistryPath = Join-Path $registryRoot "$testId-migration"
$unsafeMigrationRegistryPath = Join-Path $registryRoot "$testId-unsafe-migration"
$legacyRegistryPath = Join-Path $registryRoot "$testId-legacy"
$statePath = Join-Path $testRoot 'State\onedrive-sync.json'
$migrationStatePath = Join-Path $testRoot 'MigrationState\onedrive-sync.json'
$unsafeMigrationStatePath = Join-Path $testRoot 'UnsafeMigrationState\onedrive-sync.json'
$wrapperStatePath = Join-Path $testRoot 'WrapperState\onedrive-sync.json'
$legacyStatePath = Join-Path $testRoot 'LegacyState\onedrive-sync.json'
$oldLocalAppData = $env:LOCALAPPDATA
$oldCI = $env:CI
$oldOneDriveConsumer = $env:OneDriveConsumer
$oldOneDrive = $env:OneDrive
$oldOneDriveCommercial = $env:OneDriveCommercial
$oldVanDykeSshAuthSock = $env:VANDYKE_SSH_AUTH_SOCK
$oldSecureCrtConfigSyncTestMode = $env:SECURECRT_CONFIG_SYNC_TEST_MODE
$oldTestAgentState = $env:SECURECRT_CONFIG_SYNC_TEST_AGENT_STATE
$oldTestNoninteractive = $env:SECURECRT_CONFIG_SYNC_TEST_NONINTERACTIVE

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

function Assert-FileBackedSshKeysDisabled {
    param([Parameter(Mandatory)][string]$ConfigurationPath)

    $lines = [IO.File]::ReadAllLines((Join-Path $ConfigurationPath 'SSH2.ini'))
    Assert-Equal 1 @($lines | Where-Object { $_ -eq 'S:"Identity Filename V2"=' }).Count `
        'empty global identity filename count'
    Assert-Equal 1 @($lines | Where-Object {
        $_ -eq 'D:"Add Private Keys To Agent"=00000000'
    }).Count 'disabled file-key agent loading count'
    Assert-Equal 1 @($lines | Where-Object {
        $_ -eq 'Z:"Agent Keys To Load"=00000000'
    }).Count 'empty agent preload list count'
    if ($lines -match '/Users/erica/\.ssh/') {
        throw 'A macOS private-key path remained in the shared SSH2 configuration.'
    }
}

function New-TestConfiguration {
    param([Parameter(Mandatory)][string]$Root)

    $config = Join-Path $Root 'SecureCRT\Config'
    $sessionGroup = Join-Path $config 'Sessions\Example Group'
    New-Item -ItemType Directory -Path (Join-Path $sessionGroup 'VMs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $config 'Global.ini') -Value 'test global configuration'
    Set-Content -LiteralPath (Join-Path $config 'SSH2.ini') -Value @(
        'D:"Add Private Keys To Agent"=00000001',
        'S:"Identity Filename V2"=${VDS_SSH_DATA_PATH}/id_ed25519-erica_github',
        'D:"Try All Agent Keys"=00000001',
        'Z:"Agent Keys To Load"=00000003',
        ' /Users/erica/.ssh/id_ed25519-erica_github',
        ' /Users/erica/.ssh/id_rsa',
        ' /Users/erica/.ssh/id_rsa.old'
    )
    Set-Content -LiteralPath (Join-Path $sessionGroup '__FolderData__.ini') -Value 'folder metadata'
    Set-Content -LiteralPath (Join-Path $sessionGroup 'host-one.ini') `
        -Value @('S:"Hostname"=host-one.example', 'S:"Username"=erica')
    Set-Content -LiteralPath (Join-Path $sessionGroup 'VMs\host-two.ini') `
        -Value @('S:"Hostname"=host-two.example', 'S:"Username"=root')
    return $config
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:LOCALAPPDATA = Join-Path $testRoot 'LocalAppData'
    $env:VANDYKE_SSH_AUTH_SOCK = 'previous-agent'
    $env:SECURECRT_CONFIG_SYNC_TEST_MODE = '1'
    $env:SECURECRT_CONFIG_SYNC_TEST_AGENT_STATE = 'missing'
    $env:SECURECRT_CONFIG_SYNC_TEST_NONINTERACTIVE = '1'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null

    $gatePersonalPath = Join-Path $testRoot 'gate-personal'
    $gateError = $null
    try {
        & $installer `
            -ConfigPath (Join-Path $testRoot 'not-yet-configured') `
            -PersonalDataPath $gatePersonalPath `
            -RegistryPath $registryPath `
            -StatePath $statePath `
            -SkipOneDrivePin
    } catch {
        $gateError = $_.Exception.Message
    }
    if ($gateError -notmatch 'cannot wait for 1Password') {
        throw "The missing-agent gate did not fail cleanly: $gateError"
    }
    if (Test-Path -LiteralPath $gatePersonalPath) {
        throw 'The installer created Personal Data before the agent readiness gate.'
    }
    if (Test-Path -LiteralPath $statePath) {
        throw 'The installer created rollback state before the agent readiness gate.'
    }

    $env:SECURECRT_CONFIG_SYNC_TEST_AGENT_STATE = 'ready'
    Remove-Item Env:SECURECRT_CONFIG_SYNC_TEST_NONINTERACTIVE

    $configPath = New-TestConfiguration -Root (Join-Path $testRoot 'OneDrive')
    $personalPath = Join-Path $testRoot 'Personal\Config.personal'
    $existingPersonalSession = Join-Path $personalPath 'Sessions\Example Group\host-one.ini'
    New-Item -ItemType Directory -Path (Split-Path -Parent $existingPersonalSession) -Force | Out-Null
    Set-Content -LiteralPath $existingPersonalSession `
        -Value @('S:"Password V2"=preserve-me', 'S:"Username"=wrong-user')

    New-Item -Path $registryPath -Force | Out-Null
    New-ItemProperty -LiteralPath $registryPath -Name 'Config Path' `
        -PropertyType String -Value 'C:\previous\config' -Force | Out-Null
    New-ItemProperty -LiteralPath $registryPath -Name 'Personal Data Path' `
        -PropertyType String -Value 'C:\previous\personal' -Force | Out-Null
    New-ItemProperty -LiteralPath $registryPath -Name 'Store Personal Data Separately' `
        -PropertyType DWord -Value 0 -Force | Out-Null

    $firstOutput = & $installer `
        -ConfigPath $configPath `
        -PersonalDataPath $personalPath `
        -RegistryPath $registryPath `
        -StatePath $statePath `
        -SkipOneDrivePin 6>&1 | Out-String

    Assert-Equal $configPath `
        (Get-ItemPropertyValue -LiteralPath $registryPath -Name 'Config Path') `
        'Config Path'
    Assert-Equal $personalPath `
        (Get-ItemPropertyValue -LiteralPath $registryPath -Name 'Personal Data Path') `
        'Personal Data Path'
    Assert-Equal 1 `
        (Get-ItemPropertyValue -LiteralPath $registryPath `
            -Name 'Store Personal Data Separately') `
        'Store Personal Data Separately'
    Assert-FileBackedSshKeysDisabled -ConfigurationPath $configPath
    if (-not (Test-Path -LiteralPath $personalPath -PathType Container)) {
        throw 'The Personal Data folder was not created.'
    }
    if ($firstOutput -notmatch 'Saved sessions:\s+2') {
        throw "The installer reported the wrong session count:`n$firstOutput"
    }
    if ($firstOutput -notmatch 'Synced usernames:\s+2') {
        throw "The installer reported the wrong username count:`n$firstOutput"
    }
    Assert-Equal '\\.\pipe\openssh-ssh-agent' `
        $env:VANDYKE_SSH_AUTH_SOCK `
        'SecureCRT external SSH agent pipe'
    if ($firstOutput -notmatch 'External SSH agent:\s+\\\\\.\\pipe\\openssh-ssh-agent') {
        throw "The installer did not report the SSH agent pipe:`n$firstOutput"
    }
    $hostOnePersonal = Get-Content -LiteralPath $existingPersonalSession -Raw
    if ($hostOnePersonal -notmatch 'S:"Username"=erica' -or
        $hostOnePersonal -notmatch 'S:"Password V2"=preserve-me') {
        throw 'The existing Personal Data session was not merged safely.'
    }
    $hostTwoPersonalPath = Join-Path $personalPath 'Sessions\Example Group\VMs\host-two.ini'
    if ((Get-Content -LiteralPath $hostTwoPersonalPath -Raw) -notmatch 'S:"Username"=root') {
        throw 'The missing Personal Data session was not initialized.'
    }
    foreach ($helper in 'setup-onedrive-macos.sh', 'setup-onedrive-windows.ps1',
        'setup-onedrive-windows.cmd', 'disconnect-onedrive-macos.sh',
        'disconnect-onedrive-windows.ps1', 'disconnect-onedrive-windows.cmd') {
        $publishedHelper = Join-Path (Split-Path -Parent $configPath) $helper
        Assert-Equal `
            (Get-FileHash -LiteralPath (Join-Path $repoRoot $helper) -Algorithm SHA256).Hash `
            (Get-FileHash -LiteralPath $publishedHelper -Algorithm SHA256).Hash `
            "published $helper"
    }

    $backupDirectory = Join-Path $env:LOCALAPPDATA 'VanDyke\SecureCRT-Setup-Backups'
    $backups = @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' -File)
    Assert-Equal 1 $backups.Count 'first-run backup count'
    $backup = Get-Content -LiteralPath $backups[0].FullName -Raw | ConvertFrom-Json
    Assert-Equal 'C:\previous\config' $backup.ConfigPath 'backed-up Config Path'
    Assert-Equal 'C:\previous\personal' $backup.PersonalDataPath 'backed-up Personal Data Path'
    Assert-Equal 0 $backup.StorePersonalDataSeparately `
        'backed-up Store Personal Data Separately'
    Assert-Equal 'previous-agent' $backup.VanDykeSshAuthSock 'backed-up SSH agent pipe'
    $setupState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Equal $true $setupState.Active 'active setup state'
    Assert-Equal 'C:\previous\config' $setupState.ConfigPathBefore `
        'recorded previous Config Path'

    & $installer `
        -ConfigPath $configPath `
        -PersonalDataPath $personalPath `
        -RegistryPath $registryPath `
        -StatePath $statePath `
        -SkipOneDrivePin | Out-Null
    $backups = @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' -File)
    Assert-Equal 1 $backups.Count 'second-run backup count'

    $dryRunOutput = & $disconnect -StatePath $statePath -DryRun 6>&1 | Out-String
    if ($dryRunOutput -notmatch 'SecureCRT disconnect dry run:') {
        throw "Disconnect did not report its dry run:`n$dryRunOutput"
    }
    Assert-Equal $configPath `
        (Get-ItemPropertyValue -LiteralPath $registryPath -Name 'Config Path') `
        'Config Path after disconnect dry run'
    $setupState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Equal $true $setupState.Active 'setup state after disconnect dry run'

    New-ItemProperty -LiteralPath $registryPath -Name 'Personal Data Path' `
        -PropertyType String -Value 'C:\user\changed\personal' -Force | Out-Null
    $disconnectOutput = & $disconnect -StatePath $statePath 6>&1 | Out-String
    if ($disconnectOutput -notmatch 'SecureCRT disconnected:') {
        throw "Disconnect did not report completion:`n$disconnectOutput"
    }
    if ($disconnectOutput -notmatch
        'left unchanged: Personal Data path changed after setup') {
        throw "Disconnect did not report its ownership guard:`n$disconnectOutput"
    }
    Assert-Equal 'C:\previous\config' `
        (Get-ItemPropertyValue -LiteralPath $registryPath -Name 'Config Path') `
        'restored Config Path'
    Assert-Equal 'C:\user\changed\personal' `
        (Get-ItemPropertyValue -LiteralPath $registryPath -Name 'Personal Data Path') `
        'preserved user-changed Personal Data Path'
    Assert-Equal 0 `
        (Get-ItemPropertyValue -LiteralPath $registryPath `
            -Name 'Store Personal Data Separately') `
        'restored Personal Data separation setting'
    Assert-Equal 'previous-agent' $env:VANDYKE_SSH_AUTH_SOCK `
        'restored external-agent environment value'
    $setupState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Equal $false $setupState.Active 'inactive setup state'
    if (-not (Test-Path -LiteralPath $configPath -PathType Container) -or
        -not (Test-Path -LiteralPath $personalPath -PathType Container)) {
        throw 'Disconnect removed shared configuration or Personal Data.'
    }
    $secondDisconnectOutput = & $disconnect -StatePath $statePath 6>&1 | Out-String
    if ($secondDisconnectOutput -notmatch 'already disconnected') {
        throw "Second disconnect was not idempotent:`n$secondDisconnectOutput"
    }

    $legacyPersonalPath = Join-Path $testRoot 'LegacyPersonal\Config.personal'
    New-Item -Path $legacyRegistryPath -Force | Out-Null
    New-ItemProperty -LiteralPath $legacyRegistryPath -Name 'Config Path' `
        -PropertyType String -Value $configPath -Force | Out-Null
    New-ItemProperty -LiteralPath $legacyRegistryPath -Name 'Personal Data Path' `
        -PropertyType String -Value $legacyPersonalPath -Force | Out-Null
    New-ItemProperty -LiteralPath $legacyRegistryPath `
        -Name 'Store Personal Data Separately' -PropertyType DWord `
        -Value 1 -Force | Out-Null
    $env:VANDYKE_SSH_AUTH_SOCK = '\\.\pipe\openssh-ssh-agent'
    $legacyBackupPath = Join-Path $backupDirectory `
        'configuration-paths-legacy-test.json'
    [ordered]@{
        RegistryPath = $legacyRegistryPath
        ConfigPath = 'C:\legacy\config'
        PersonalDataPath = 'C:\legacy\personal'
        StorePersonalDataSeparately = 0
        VanDykeSshAuthSock = 'legacy-agent'
    } | ConvertTo-Json | Set-Content -LiteralPath $legacyBackupPath -Encoding UTF8

    & $installer `
        -ConfigPath $configPath `
        -PersonalDataPath $legacyPersonalPath `
        -RegistryPath $legacyRegistryPath `
        -StatePath $legacyStatePath `
        -SkipOneDrivePin | Out-Null
    $legacySetupState = Get-Content -LiteralPath $legacyStatePath -Raw |
        ConvertFrom-Json
    Assert-Equal 'C:\legacy\config' $legacySetupState.ConfigPathBefore `
        'legacy rollback Config Path'
    Assert-Equal 'legacy-agent' $legacySetupState.VanDykeSshAuthSockBefore `
        'legacy rollback external-agent value'

    & $disconnect -StatePath $legacyStatePath | Out-Null
    Assert-Equal 'C:\legacy\config' `
        (Get-ItemPropertyValue -LiteralPath $legacyRegistryPath -Name 'Config Path') `
        'legacy restored Config Path'
    Assert-Equal 'legacy-agent' $env:VANDYKE_SSH_AUTH_SOCK `
        'legacy restored external-agent value'
    if (-not (Test-Path -LiteralPath $legacyPersonalPath -PathType Container)) {
        throw 'Legacy disconnect removed Personal Data.'
    }

    $migrationSource = New-TestConfiguration -Root (Join-Path $testRoot 'LocalOrigin')
    $migrationOneDrive = Join-Path $testRoot 'OriginOneDrive'
    $migrationTarget = Join-Path $migrationOneDrive 'SecureCRT\Config'
    $migrationPersonal = Join-Path $testRoot 'MigrationPersonal\Config.personal'
    New-Item -ItemType Directory -Path $migrationOneDrive -Force | Out-Null
    New-Item -Path $migrationRegistryPath -Force | Out-Null
    New-ItemProperty -LiteralPath $migrationRegistryPath -Name 'Config Path' `
        -PropertyType String -Value $migrationSource -Force | Out-Null
    New-ItemProperty -LiteralPath $migrationRegistryPath -Name 'Personal Data Path' `
        -PropertyType String -Value 'C:\previous\migration-personal' -Force | Out-Null
    $env:OneDriveConsumer = $migrationOneDrive
    $env:OneDrive = $null
    $env:OneDriveCommercial = $null

    $migrationOutput = & $installer `
        -PersonalDataPath $migrationPersonal `
        -RegistryPath $migrationRegistryPath `
        -StatePath $migrationStatePath `
        -SkipOneDrivePin 6>&1 | Out-String
    if ($migrationOutput -notmatch 'Migrated the existing SecureCRT configuration:') {
        throw "The installer did not report the Windows-origin migration:`n$migrationOutput"
    }
    Assert-Equal $migrationTarget `
        (Get-ItemPropertyValue -LiteralPath $migrationRegistryPath -Name 'Config Path') `
        'migrated Config Path'
    Assert-Equal `
        (Get-FileHash -LiteralPath (Join-Path $migrationSource 'Global.ini') -Algorithm SHA256).Hash `
        (Get-FileHash -LiteralPath (Join-Path $migrationTarget 'Global.ini') -Algorithm SHA256).Hash `
        'migrated Global.ini'
    Assert-FileBackedSshKeysDisabled -ConfigurationPath $migrationTarget
    if ((Get-Content -LiteralPath (Join-Path $migrationSource 'SSH2.ini') -Raw) -notmatch
        '/Users/erica/\.ssh/id_rsa') {
        throw 'The origin migration modified the original local SSH2 configuration.'
    }
    if (-not (Test-Path -LiteralPath $migrationSource -PathType Container)) {
        throw 'The Windows-origin migration removed the original local configuration.'
    }
    foreach ($helper in 'setup-onedrive-macos.sh', 'setup-onedrive-windows.ps1',
        'setup-onedrive-windows.cmd', 'disconnect-onedrive-macos.sh',
        'disconnect-onedrive-windows.ps1', 'disconnect-onedrive-windows.cmd') {
        $publishedHelper = Join-Path (Split-Path -Parent $migrationTarget) $helper
        Assert-Equal `
            (Get-FileHash -LiteralPath (Join-Path $repoRoot $helper) -Algorithm SHA256).Hash `
            (Get-FileHash -LiteralPath $publishedHelper -Algorithm SHA256).Hash `
            "origin-published $helper"
    }

    $unsafeMigrationSource = New-TestConfiguration -Root (Join-Path $testRoot 'UnsafeLocalOrigin')
    Set-Content -LiteralPath (Join-Path $unsafeMigrationSource 'Sessions\Example Group\unsafe.ini') `
        -Value 'S:"Password V2"=do-not-sync'
    $unsafeMigrationOneDrive = Join-Path $testRoot 'UnsafeOriginOneDrive'
    $unsafeMigrationTarget = Join-Path $unsafeMigrationOneDrive 'SecureCRT\Config'
    $unsafeMigrationPersonal = Join-Path $testRoot 'UnsafeMigrationPersonal\Config.personal'
    New-Item -ItemType Directory -Path $unsafeMigrationOneDrive -Force | Out-Null
    New-Item -Path $unsafeMigrationRegistryPath -Force | Out-Null
    New-ItemProperty -LiteralPath $unsafeMigrationRegistryPath -Name 'Config Path' `
        -PropertyType String -Value $unsafeMigrationSource -Force | Out-Null
    $env:OneDriveConsumer = $unsafeMigrationOneDrive
    $unsafeMigrationError = $null
    try {
        & $installer `
            -PersonalDataPath $unsafeMigrationPersonal `
            -RegistryPath $unsafeMigrationRegistryPath `
            -StatePath $unsafeMigrationStatePath `
            -SkipOneDrivePin | Out-Null
    } catch {
        $unsafeMigrationError = $_.Exception.Message
    }
    if ($unsafeMigrationError -notmatch 'may contain saved credentials') {
        throw "The unsafe Windows-origin migration did not fail safely: $unsafeMigrationError"
    }
    if ((Test-Path -LiteralPath $unsafeMigrationTarget) -or
        (Test-Path -LiteralPath $unsafeMigrationPersonal) -or
        (Test-Path -LiteralPath $unsafeMigrationStatePath)) {
        throw 'The unsafe Windows-origin migration wrote shared or Personal Data files.'
    }

    $wrapperPersonalPath = Join-Path $testRoot 'WrapperPersonal\Config.personal'
    $env:CI = 'true'
    & $wrapper `
        -ConfigPath $configPath `
        -PersonalDataPath $wrapperPersonalPath `
        -RegistryPath $wrapperRegistryPath `
        -StatePath $wrapperStatePath `
        -SkipOneDrivePin
    if ($LASTEXITCODE -ne 0) {
        throw "The CMD wrapper failed with exit code $LASTEXITCODE."
    }
    Assert-Equal $configPath `
        (Get-ItemPropertyValue -LiteralPath $wrapperRegistryPath -Name 'Config Path') `
        'wrapper Config Path'
    Assert-Equal 1 `
        (Get-ItemPropertyValue -LiteralPath $wrapperRegistryPath `
            -Name 'Store Personal Data Separately') `
        'wrapper Store Personal Data Separately'
    & $disconnectWrapper -StatePath $wrapperStatePath -DryRun
    if ($LASTEXITCODE -ne 0) {
        throw "The disconnect CMD wrapper failed with exit code $LASTEXITCODE."
    }

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

    $partialConfig = Join-Path $testRoot 'partial-config'
    New-Item -ItemType Directory -Path $partialConfig -Force | Out-Null
    try {
        & $installer `
            -ConfigPath $partialConfig `
            -PersonalDataPath $personalPath `
            -RegistryPath $registryPath `
            -SkipOneDrivePin | Out-Null
        throw 'Expected a missing configuration to fail.'
    } catch {
        if ($_.Exception.Message -notmatch 'exists but is incomplete') {
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
    $env:VANDYKE_SSH_AUTH_SOCK = $oldVanDykeSshAuthSock
    $env:SECURECRT_CONFIG_SYNC_TEST_MODE = $oldSecureCrtConfigSyncTestMode
    $env:SECURECRT_CONFIG_SYNC_TEST_AGENT_STATE = $oldTestAgentState
    $env:SECURECRT_CONFIG_SYNC_TEST_NONINTERACTIVE = $oldTestNoninteractive
    Remove-Item -LiteralPath $registryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $wrapperRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $migrationRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $unsafeMigrationRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $legacyRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
