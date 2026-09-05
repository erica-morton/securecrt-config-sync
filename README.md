# SecureCRT Config Sync

Cross-platform bootstrap helpers for using a shared SecureCRT configuration
from OneDrive while keeping passwords, passphrases, automated logon data, and
private keys local to each computer. Session usernames may be shared as
ordinary connection metadata.

The project configures SecureCRT; it does not install SecureCRT or OneDrive.
The 1Password desktop app with its SSH agent enabled is a required part of the
configuration on both platforms.
It is not affiliated with or endorsed by VanDyke Software, Inc.

## What it does

- discovers an existing `OneDrive/SecureCRT/Config` tree or safely creates it
  from the machine's current local SecureCRT configuration;
- asks SecureCRT and SecureFX to quit cleanly and never force-terminates them;
- refuses configurations whose session files appear to contain saved
  passwords or passphrases;
- creates a machine-local Personal Data folder and explicitly enables it;
- initializes its session usernames from the shared connection metadata;
- configures SecureCRT's shared and personal paths on macOS or Windows;
- connects SecureCRT to the 1Password/OpenSSH agent without copying private
  keys into its configuration;
- removes global identity-file and key-preload entries so SecureCRT does not
  try to open another computer's private-key paths;
- pins the SecureCRT tree for offline use on Windows;
- backs up previous path settings before changing them;
- records a machine-local rollback manifest without storing credentials;
- publishes all platform helpers next to the shared `Config` folder; and
- verifies its changes and supports safe, idempotent reruns.

## Start or join a shared configuration

Keep the three `setup-onedrive-*` and three `disconnect-onedrive-*` files
together. A Git checkout is not
required; they can be obtained by downloading and extracting this repository.

If `OneDrive/SecureCRT/Config` already exists, the helper joins that shared
configuration. If it does not, the helper finds SecureCRT's currently
configured local tree and a single OneDrive account, validates the local tree,
copies it through a temporary staging directory, and creates:

```text
OneDrive/SecureCRT/Config
```

The original local configuration is retained as a fallback. Both helpers then
publish the complete Mac and Windows setup package beside `Config`, allowing
the next Mac or Windows computer to join directly from OneDrive.

Before originating a new share, using SecureCRT's local Personal Data folder
is recommended. The helpers reject common saved-password and passphrase
markers before creating anything in OneDrive; they never migrate the Personal
Data folder or private keys.

## macOS setup

Run through `bash` so setup also works when OneDrive has not retained the
script's executable permission:

```bash
bash ./setup-onedrive-macos.sh
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
bash ./setup-onedrive-macos.sh \
  --config "/path/to/OneDrive/SecureCRT/Config" \
  --personal "/path/to/local/Config.personal"
```

The Mac helper can originate or join the share. It requires the 1Password SSH
agent socket and creates a user
LaunchAgent so SecureCRT opened from Finder or the Dock inherits that socket
after every login. If 1Password or its agent is unavailable, interactive setup
shows the required steps, waits, retests, and continues when the agent is
ready. It also publishes all macOS and Windows setup and disconnect helpers
into the OneDrive `SecureCRT` folder.

### The built-in macOS SSH agent

macOS ships `/System/Library/LaunchAgents/com.openssh.ssh-agent.plist`, whose
`Sockets` > `Listeners` > `SecureSocketWithKey` entry tells launchd to publish
the built-in agent's socket as `SSH_AUTH_SOCK`. launchd injects that value into
every application started through Launch Services, and the injection takes
precedence over `launchctl setenv`. A GUI SecureCRT therefore reaches the
built-in agent, which holds no keys, and falls back to password prompts on
every session even though the LaunchAgent above is installed correctly.

`launchctl getenv SSH_AUTH_SOCK` keeps reporting the value setup wrote, so it
cannot detect this. Setup instead disables the built-in agent for the current
user and then verifies the result by reading the `SSH_AUTH_SOCK` that a small
throwaway application launched through Launch Services actually inherits.

System Integrity Protection does not allow unloading the built-in agent from a
running login session, so on a machine where it was still active setup asks for
one log out and back in. Disconnect re-enables the built-in agent, but only
when setup is the component that disabled it.

Disabling the job needs root. `/var/db/com.apple.xpc.launchd` is owned by root,
and an unelevated `launchctl disable` still exits 0 and still shows the job as
disabled in `launchctl print-disabled`, while writing nothing — so the built-in
agent returns at the next login and the password prompts come back. Setup
confirms the label actually landed in the override database and, when it did
not, prints the elevated command to run:

```bash
sudo launchctl disable gui/$(id -u)/com.openssh.ssh-agent
```

## Windows setup

On the first Windows computer, extract all six helpers together and
double-click the CMD file. On later computers, open the synchronized
`OneDrive\SecureCRT` folder and double-click the same file:

```text
setup-onedrive-windows.cmd
```

The setup itself does not require administrator access, though disabling the
Windows OpenSSH Authentication Agent service may require elevation once. The
default Personal Data folder is:

```text
%APPDATA%\VanDyke\SecureCRT\Config.personal
```

For an explicit shared configuration path, run PowerShell:

```powershell
.\setup-onedrive-windows.ps1 `
  -ConfigPath 'C:\path\to\OneDrive\SecureCRT\Config'
```

The Windows helper can originate or join the share and publishes all macOS and
Windows setup and disconnect helpers into it. It requires 1Password to be
running with **Settings > Developer > Use the SSH Agent** enabled. It verifies
that the 1Password agent owns the
standard `\\.\pipe\openssh-ssh-agent` pipe, then sets SecureCRT's
`VANDYKE_SSH_AUTH_SOCK` user environment variable to that pipe. If the Windows
OpenSSH Authentication Agent service is running, setup explains how to stop
and disable it so 1Password can own the pipe. Interactive setup waits while
those steps are completed, retests the agent, and then continues. A
non-interactive run fails fast instead of hanging.

## Disconnect or roll back one computer

Disconnect restores only the machine-local settings captured by setup. It
does not uninstall SecureCRT, modify or delete the shared OneDrive `Config`
tree, remove 1Password, or delete the local Personal Data folder.

Preview the macOS rollback, then apply it:

```bash
bash ./disconnect-onedrive-macos.sh --dry-run
bash ./disconnect-onedrive-macos.sh
```

On Windows, double-click `disconnect-onedrive-windows.cmd`, or preview it from
PowerShell:

```powershell
.\disconnect-onedrive-windows.ps1 -DryRun
```

Setup records the values it replaced and the values it installed. Disconnect
restores a setting only when it still has the installed value; a setting
changed later by the user or another tool is left untouched and reported.
Successful disconnects are idempotent. Rerunning the current setup after an
older installation creates rollback state from compatible setup backup
history, with a retained local SecureCRT configuration as a safe fallback.

The default state manifests are machine-local:

```text
macOS:
~/Library/Application Support/VanDyke/SecureCRT/Setup State/onedrive-sync.plist

Windows:
%LOCALAPPDATA%\VanDyke\SecureCRT-Setup-State\onedrive-sync.json
```

## Daily use

With enough SecureCRT licenses for simultaneous use, clients may remain open on
multiple computers for normal terminal work. Avoid changing the same shared
session or preference on two computers at once, and allow OneDrive to finish
syncing after configuration changes before editing them elsewhere. VanDyke's
[licensing FAQ](https://www.vandyke.com/products/securecrt/faq/index.html)
allows a single-user license to be installed on multiple computers only when
the software is used on one computer at a time; simultaneous use requires
another license.

The shared `Config` tree can contain sessions and their usernames, global
preferences, default session settings, color schemes, button bars, and host-key
data. During setup, the helpers also merge those usernames into the local
Personal Data tree without replacing existing credential fields. Credentials,
Personal Data, and private key material stay local.

Agent integration authenticates primary connections only. It does not enable
SSH agent forwarding into remote hosts.

## Tests and limits

GitHub Actions runs native integration tests on macOS and Windows and applies
PSScriptAnalyzer to every PowerShell file. Tests cover
path discovery, saved-credential rejection, backup creation, preferences and
registry writes, helper deployment, validation failures, CMD argument
forwarding, session counts, first-machine migrations, pre-copy credential
safety, Personal Data enablement, removal of file-backed SSH keys,
external-agent settings, rollback-state creation, disconnect dry runs,
ownership guards, exact restoration, retained data, and idempotent reruns.

Hosted CI cannot authenticate to a real OneDrive account or launch a licensed
SecureCRT installation. OneDrive hydration and the first actual SecureCRT
launch remain smoke tests on each real computer.

## License

MIT. See [LICENSE](LICENSE).
