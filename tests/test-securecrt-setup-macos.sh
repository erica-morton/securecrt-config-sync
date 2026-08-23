#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
installer="$repo_root/setup-onedrive-macos.sh"
template_dir="$(dirname "$installer")"
test_root="$(mktemp -d)"
preferences_domain="io.github.securecrtconfigsync.test.$$"

cleanup() {
  defaults delete "$preferences_domain" >/dev/null 2>&1 || true
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

config_path="$test_root/OneDrive/SecureCRT/Config"
personal_path="$test_root/Personal/Config.personal"
session_group="$config_path/Sessions/Example Group"
mkdir -p "$session_group/VMs" "$test_root/home"
printf 'test global configuration\n' >"$config_path/Global.ini"
printf 'folder metadata\n' >"$session_group/__FolderData__.ini"
printf 'host one\n' >"$session_group/host-one.ini"
printf 'host two\n' >"$session_group/VMs/host-two.ini"

defaults write "$preferences_domain" "Config Path" -string "/previous/config"
defaults write "$preferences_domain" "Personal Data Path" -string "/previous/personal"

first_output="$(
  HOME="$test_root/home" "$installer" \
    --config "$config_path" \
    --personal "$personal_path" \
    --preferences-domain "$preferences_domain"
)"

normalized_config="$(cd "$config_path" && pwd -P)"
normalized_personal="$(cd "$personal_path" && pwd -P)"
assert_equal "$normalized_config" "$(defaults read "$preferences_domain" "Config Path")" "Config Path"
assert_equal "$normalized_personal" "$(defaults read "$preferences_domain" "Personal Data Path")" "Personal Data Path"

printf '%s\n' "$first_output" | grep -Eq 'Saved sessions: +2'
cmp "$template_dir/setup-onedrive-macos.sh" "$test_root/OneDrive/SecureCRT/setup-onedrive-macos.sh"
cmp "$template_dir/setup-onedrive-windows.ps1" "$test_root/OneDrive/SecureCRT/setup-onedrive-windows.ps1"
cmp "$template_dir/setup-onedrive-windows.cmd" "$test_root/OneDrive/SecureCRT/setup-onedrive-windows.cmd"

backup_dir="$test_root/home/Library/Application Support/VanDyke/SecureCRT/Setup Backups"
backup_count="$(find "$backup_dir" -type f -name 'configuration-paths-*.txt' | wc -l | tr -d ' ')"
assert_equal "1" "$backup_count" "first-run backup count"

HOME="$test_root/home" "$installer" \
  --config "$config_path" \
  --personal "$personal_path" \
  --preferences-domain "$preferences_domain" >/dev/null
backup_count="$(find "$backup_dir" -type f -name 'configuration-paths-*.txt' | wc -l | tr -d ' ')"
assert_equal "1" "$backup_count" "second-run backup count"

if HOME="$test_root/home" "$installer" \
    --config "$test_root/missing" \
    --personal "$personal_path" \
    --preferences-domain "$preferences_domain" >/dev/null 2>&1; then
  echo "Expected an incomplete configuration to fail." >&2
  exit 1
fi

printf 'S:"Password V2"=do-not-sync\n' >"$session_group/unsafe.ini"
if HOME="$test_root/home" "$installer" \
    --config "$config_path" \
    --personal "$personal_path" \
    --preferences-domain "$preferences_domain" >/dev/null 2>&1; then
  echo "Expected a configuration containing saved credentials to fail." >&2
  exit 1
fi
rm "$session_group/unsafe.ini"

echo "macOS SecureCRT setup integration test passed."
