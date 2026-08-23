#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
installer="$repo_root/setup-onedrive-macos.sh"
template_dir="$(dirname "$installer")"
test_root="$(mktemp -d)"
preferences_domain="io.github.securecrtconfigsync.test.$$"
migration_domain="io.github.securecrtconfigsync.migration.test.$$"
unsafe_migration_domain="io.github.securecrtconfigsync.unsafe-migration.test.$$"
agent_pid=""

cleanup() {
  defaults delete "$preferences_domain" >/dev/null 2>&1 || true
  defaults delete "$migration_domain" >/dev/null 2>&1 || true
  defaults delete "$unsafe_migration_domain" >/dev/null 2>&1 || true
  if [ -n "$agent_pid" ]; then
    kill "$agent_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT

assert_equal() {
  expected="$1"
  actual="$2"
  label="$3"
  if [ "$expected" != "$actual" ]; then
    printf 'Expected %s to be %q, got %q\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

write_file_backed_ssh2_config() {
  target="$1"
  printf '%s\r\n' \
    'D:"Add Private Keys To Agent"=00000001' \
    'S:"Identity Filename V2"=${VDS_SSH_DATA_PATH}/id_ed25519-erica_github' \
    'D:"Try All Agent Keys"=00000001' \
    'Z:"Agent Keys To Load"=00000003' \
    ' /Users/erica/.ssh/id_ed25519-erica_github' \
    ' /Users/erica/.ssh/id_rsa' \
    ' /Users/erica/.ssh/id_rsa.old' >"$target"
}

assert_file_backed_ssh_keys_disabled() {
  configuration_path="$1"
  ssh2_path="$configuration_path/SSH2.ini"
  grep -Fqx $'S:"Identity Filename V2"=\r' "$ssh2_path"
  grep -Fqx $'D:"Add Private Keys To Agent"=00000000\r' "$ssh2_path"
  grep -Fqx $'Z:"Agent Keys To Load"=00000000\r' "$ssh2_path"
  if grep -Fq '/Users/erica/.ssh/' "$ssh2_path"; then
    echo "A macOS private-key path remained in $ssh2_path." >&2
    exit 1
  fi
}

config_path="$test_root/OneDrive/SecureCRT/Config"
personal_path="$test_root/Personal/Config.personal"
session_group="$config_path/Sessions/Example Group"
mkdir -p "$session_group/VMs" "$test_root/home"
printf 'test global configuration\n' >"$config_path/Global.ini"
write_file_backed_ssh2_config "$config_path/SSH2.ini"
printf 'folder metadata\n' >"$session_group/__FolderData__.ini"
printf 'S:"Hostname"=host-one.example\r\nS:"Username"=erica\r\nS:"Password V2"=\r\n' \
  >"$session_group/host-one.ini"
printf 'S:"Hostname"=host-two.example\r\nS:"Username"=root\r\n' >"$session_group/VMs/host-two.ini"
mkdir -p "$personal_path/Sessions/Example Group"
printf '\357\273\277S:"Password V2"=preserve-me\r\nS:"Username"=wrong-user\r\n' \
  >"$personal_path/Sessions/Example Group/host-one.ini"

gate_home="$test_root/gate-home"
gate_personal="$test_root/gate-personal"
gate_output="$test_root/gate-output.txt"
if HOME="$gate_home" \
    SECURECRT_SYNC_ONEPASSWORD_APP="$test_root/missing-1Password.app" \
    SECURECRT_SYNC_ONEPASSWORD_SOCKET="$test_root/missing-agent.sock" \
    "$installer" \
    --config "$config_path" \
    --personal "$gate_personal" \
    --preferences-domain "$preferences_domain" \
    </dev/null >"$gate_output" 2>&1; then
  echo "The installer accepted a missing 1Password SSH agent." >&2
  exit 1
fi
grep -Fq '1Password SSH agent setup is required' "$gate_output"
grep -Fq 'Setup is non-interactive' "$gate_output"
if [ -e "$gate_personal" ] || [ -e "$gate_home/Library/LaunchAgents" ]; then
  echo "The installer changed local configuration before the agent readiness gate." >&2
  exit 1
fi

agent_socket="$test_root/1password-agent.sock"
onepassword_app="$test_root/1Password.app"
launchctl_state="$test_root/launchctl-ssh-auth-sock"
mock_launchctl="$test_root/mock-launchctl.sh"
mkdir -p "$onepassword_app"
eval "$(/usr/bin/ssh-agent -a "$agent_socket" -s)" >/dev/null
agent_pid="$SSH_AGENT_PID"
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'case "$1" in' \
  '  setenv) printf "%s" "$3" >"$SECURECRT_SYNC_LAUNCHCTL_STATE" ;;' \
  '  getenv) [ ! -f "$SECURECRT_SYNC_LAUNCHCTL_STATE" ] || cat "$SECURECRT_SYNC_LAUNCHCTL_STATE" ;;' \
  '  bootout|bootstrap) ;;' \
  '  *) exit 1 ;;' \
  'esac' >"$mock_launchctl"
chmod 0755 "$mock_launchctl"

defaults write "$preferences_domain" "Config Path" -string "/previous/config"
defaults write "$preferences_domain" "Personal Data Path" -string "/previous/personal"
defaults write "$preferences_domain" "Store Personal Data Separately" -bool false

first_output="$(
  HOME="$test_root/home" \
  SECURECRT_SYNC_ONEPASSWORD_APP="$onepassword_app" \
  SECURECRT_SYNC_ONEPASSWORD_SOCKET="$agent_socket" \
  SECURECRT_SYNC_LAUNCHCTL="$mock_launchctl" \
  SECURECRT_SYNC_LAUNCHCTL_STATE="$launchctl_state" \
  "$installer" \
    --config "$config_path" \
    --personal "$personal_path" \
    --preferences-domain "$preferences_domain"
)"

normalized_config="$(cd "$config_path" && pwd -P)"
normalized_personal="$(cd "$personal_path" && pwd -P)"
assert_equal "$normalized_config" "$(defaults read "$preferences_domain" "Config Path")" "Config Path"
assert_equal "$normalized_personal" "$(defaults read "$preferences_domain" "Personal Data Path")" "Personal Data Path"
assert_equal "1" "$(defaults read "$preferences_domain" "Store Personal Data Separately")" \
  "Store Personal Data Separately"
assert_file_backed_ssh_keys_disabled "$config_path"

printf '%s\n' "$first_output" | grep -Eq 'Saved sessions: +2'
printf '%s\n' "$first_output" | grep -Eq 'Synced usernames: +2'
printf '%s\n' "$first_output" | grep -Fq "External SSH agent:    $agent_socket"
assert_equal "$agent_socket" "$(cat "$launchctl_state")" "GUI SSH agent socket"
launch_agent="$test_root/home/Library/LaunchAgents/com.securecrt-config-sync.ssh-agent.plist"
grep -Fq "$agent_socket" "$launch_agent"
grep -Fq 'S:"Username"=erica' "$personal_path/Sessions/Example Group/host-one.ini"
grep -Fq 'S:"Password V2"=preserve-me' "$personal_path/Sessions/Example Group/host-one.ini"
grep -Fq 'S:"Username"=root' "$personal_path/Sessions/Example Group/VMs/host-two.ini"
cmp "$template_dir/setup-onedrive-macos.sh" "$test_root/OneDrive/SecureCRT/setup-onedrive-macos.sh"
cmp "$template_dir/setup-onedrive-windows.ps1" "$test_root/OneDrive/SecureCRT/setup-onedrive-windows.ps1"
cmp "$template_dir/setup-onedrive-windows.cmd" "$test_root/OneDrive/SecureCRT/setup-onedrive-windows.cmd"

backup_dir="$test_root/home/Library/Application Support/VanDyke/SecureCRT/Setup Backups"
backup_count="$(find "$backup_dir" -type f -name 'configuration-paths-*.txt' | wc -l | tr -d ' ')"
assert_equal "1" "$backup_count" "first-run backup count"
backup_file="$(find "$backup_dir" -type f -name 'configuration-paths-*.txt' -print -quit)"
grep -Fq 'Store Personal Data Separately=0' "$backup_file"

HOME="$test_root/home" \
SECURECRT_SYNC_ONEPASSWORD_APP="$onepassword_app" \
SECURECRT_SYNC_ONEPASSWORD_SOCKET="$agent_socket" \
SECURECRT_SYNC_LAUNCHCTL="$mock_launchctl" \
SECURECRT_SYNC_LAUNCHCTL_STATE="$launchctl_state" \
"$installer" \
  --config "$config_path" \
  --personal "$personal_path" \
  --preferences-domain "$preferences_domain" >/dev/null
backup_count="$(find "$backup_dir" -type f -name 'configuration-paths-*.txt' | wc -l | tr -d ' ')"
assert_equal "1" "$backup_count" "second-run backup count"

migration_home="$test_root/migration-home"
migration_source="$migration_home/Library/Application Support/VanDyke/SecureCRT/Config"
migration_one_drive="$migration_home/Library/CloudStorage/OneDrive-Origin"
migration_target="$migration_one_drive/SecureCRT/Config"
migration_personal="$migration_home/Library/Application Support/VanDyke/SecureCRT/Config.personal"
mkdir -p "$(dirname "$migration_source")" "$migration_one_drive"
/usr/bin/ditto "$config_path" "$migration_source"
write_file_backed_ssh2_config "$migration_source/SSH2.ini"
defaults write "$migration_domain" "Config Path" -string "$migration_source"

migration_output="$(
  HOME="$migration_home" \
  SECURECRT_SYNC_ONEPASSWORD_APP="$onepassword_app" \
  SECURECRT_SYNC_ONEPASSWORD_SOCKET="$agent_socket" \
  SECURECRT_SYNC_LAUNCHCTL="$mock_launchctl" \
  SECURECRT_SYNC_LAUNCHCTL_STATE="$launchctl_state" \
  bash "$installer" \
    --personal "$migration_personal" \
    --preferences-domain "$migration_domain"
)"
printf '%s\n' "$migration_output" | grep -Fq 'Migrated the existing SecureCRT configuration:'
normalized_migration_target="$(cd "$migration_target" && pwd -P)"
assert_equal "$normalized_migration_target" "$(defaults read "$migration_domain" "Config Path")" \
  "migrated Config Path"
cmp "$migration_source/Global.ini" "$migration_target/Global.ini"
diff -qr "$migration_source/Sessions" "$migration_target/Sessions" >/dev/null
assert_file_backed_ssh_keys_disabled "$migration_target"
grep -Fq '/Users/erica/.ssh/id_rsa' "$migration_source/SSH2.ini"
[ -d "$migration_source" ]
cmp "$template_dir/setup-onedrive-macos.sh" "$migration_one_drive/SecureCRT/setup-onedrive-macos.sh"
cmp "$template_dir/setup-onedrive-windows.ps1" "$migration_one_drive/SecureCRT/setup-onedrive-windows.ps1"
cmp "$template_dir/setup-onedrive-windows.cmd" "$migration_one_drive/SecureCRT/setup-onedrive-windows.cmd"

unsafe_migration_home="$test_root/unsafe-migration-home"
unsafe_migration_source="$unsafe_migration_home/Library/Application Support/VanDyke/SecureCRT/Config"
unsafe_migration_one_drive="$unsafe_migration_home/Library/CloudStorage/OneDrive-Origin"
unsafe_migration_target="$unsafe_migration_one_drive/SecureCRT/Config"
unsafe_migration_personal="$unsafe_migration_home/Library/Application Support/VanDyke/SecureCRT/Config.personal"
mkdir -p "$(dirname "$unsafe_migration_source")" "$unsafe_migration_one_drive"
/usr/bin/ditto "$config_path" "$unsafe_migration_source"
printf 'S:"Password V2"=do-not-sync\n' \
  >"$unsafe_migration_source/Sessions/Example Group/unsafe.ini"
defaults write "$unsafe_migration_domain" "Config Path" -string "$unsafe_migration_source"
if HOME="$unsafe_migration_home" \
    SECURECRT_SYNC_ONEPASSWORD_APP="$onepassword_app" \
    SECURECRT_SYNC_ONEPASSWORD_SOCKET="$agent_socket" \
    SECURECRT_SYNC_LAUNCHCTL="$mock_launchctl" \
    SECURECRT_SYNC_LAUNCHCTL_STATE="$launchctl_state" \
    bash "$installer" \
    --personal "$unsafe_migration_personal" \
    --preferences-domain "$unsafe_migration_domain" >/dev/null 2>&1; then
  echo "The installer migrated a local configuration containing credentials." >&2
  exit 1
fi
if [ -e "$unsafe_migration_target" ] || [ -e "$unsafe_migration_personal" ]; then
  echo "The unsafe migration changed OneDrive or Personal Data before validation." >&2
  exit 1
fi

partial_config="$test_root/missing"
mkdir -p "$partial_config"
if HOME="$test_root/home" \
    SECURECRT_SYNC_ONEPASSWORD_APP="$onepassword_app" \
    SECURECRT_SYNC_ONEPASSWORD_SOCKET="$agent_socket" \
    SECURECRT_SYNC_LAUNCHCTL="$mock_launchctl" \
    SECURECRT_SYNC_LAUNCHCTL_STATE="$launchctl_state" \
    "$installer" \
    --config "$partial_config" \
    --personal "$personal_path" \
    --preferences-domain "$preferences_domain" >/dev/null 2>&1; then
  echo "Expected an incomplete configuration to fail." >&2
  exit 1
fi

printf 'S:"Password V2"=do-not-sync\n' >"$session_group/unsafe.ini"
if HOME="$test_root/home" \
    SECURECRT_SYNC_ONEPASSWORD_APP="$onepassword_app" \
    SECURECRT_SYNC_ONEPASSWORD_SOCKET="$agent_socket" \
    SECURECRT_SYNC_LAUNCHCTL="$mock_launchctl" \
    SECURECRT_SYNC_LAUNCHCTL_STATE="$launchctl_state" \
    "$installer" \
    --config "$config_path" \
    --personal "$personal_path" \
    --preferences-domain "$preferences_domain" >/dev/null 2>&1; then
  echo "Expected a configuration containing saved credentials to fail." >&2
  exit 1
fi
rm "$session_group/unsafe.ini"

echo "macOS SecureCRT setup integration test passed."
