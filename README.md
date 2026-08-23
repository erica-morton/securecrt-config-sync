# SecureCRT Config Sync

Cross-platform bootstrap helpers for using a shared SecureCRT configuration
from OneDrive while keeping usernames, passwords, passphrases, automated logon
data, and private keys local to each computer.

The project configures SecureCRT; it does not install SecureCRT or OneDrive.
It is not affiliated with or endorsed by VanDyke Software, Inc.

## What it does

- discovers an existing `OneDrive/SecureCRT/Config` tree;
- asks SecureCRT and SecureFX to quit cleanly and never force-terminates them;
- refuses configurations whose session files appear to contain saved
  passwords or passphrases;
- creates a machine-local Personal Data folder;
- configures SecureCRT's shared and personal paths on macOS or Windows;
- pins the SecureCRT tree for offline use on Windows;
- backs up previous path settings before changing them;
- copies the platform helpers next to the shared `Config` folder; and
- verifies its changes and supports safe, idempotent reruns.

## Before the first shared setup

SecureCRT's Personal Data folder should be enabled before copying an existing
configuration into OneDrive. In SecureCRT, open **Options > Global Options >
Configuration Paths**, select a local Personal Data folder, and let SecureCRT
separate sensitive values. Then close SecureCRT and copy the public
configuration folder to:

```text
OneDrive/SecureCRT/Config
```

Do not copy the Personal Data folder, private keys, or license files into the
shared tree. The helpers intentionally stop if they find common saved-password
markers in session files.

## macOS setup

Keep the three `setup-onedrive-*` files together, then run:

```bash
chmod +x setup-onedrive-macos.sh
./setup-onedrive-macos.sh
```

The default paths are:

```text
Shared configuration:
~/Library/CloudStorage/OneDrive*/SecureCRT/Config

Local personal data:
~/Library/Application Support/VanDyke/SecureCRT/Config.personal
```

If discovery is ambiguous:

```bash
./setup-onedrive-macos.sh \
  --config "/path/to/OneDrive/SecureCRT/Config" \
  --personal "/path/to/local/Config.personal"
```

The Mac helper copies itself and the Windows helpers into the OneDrive
`SecureCRT` folder.

## Windows setup

After OneDrive synchronizes the `SecureCRT` folder, double-click:

```text
setup-onedrive-windows.cmd
```

No administrator access is required. The default Personal Data folder is:

```text
%APPDATA%\VanDyke\SecureCRT\Config.personal
```

For an explicit shared configuration path, run PowerShell:

```powershell
.\setup-onedrive-windows.ps1 `
  -ConfigPath 'C:\path\to\OneDrive\SecureCRT\Config'
```

## Daily use

Do not run SecureCRT against the shared configuration on multiple computers at
the same time. Close it on one machine and allow OneDrive to finish syncing
before opening it on another.

The shared `Config` tree can contain sessions, global preferences, default
session settings, color schemes, button bars, and host-key data. Personal Data
and private key material stay local.

## Tests and limits

GitHub Actions runs native integration tests on macOS and Windows. Tests cover
path discovery, saved-credential rejection, backup creation, preferences and
registry writes, helper deployment, validation failures, CMD argument
forwarding, session counts, and idempotent reruns.

Hosted CI cannot authenticate to a real OneDrive account or launch a licensed
SecureCRT installation. OneDrive hydration and the first actual SecureCRT
launch remain smoke tests on each real computer.

## License

MIT. See [LICENSE](LICENSE).
