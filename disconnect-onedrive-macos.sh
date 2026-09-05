#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: disconnect-onedrive-macos.sh [--state PATH] [--dry-run]

Restores the machine-local settings recorded by setup-onedrive-macos.sh.
The shared OneDrive configuration and local Personal Data are retained.
EOF
}

state_path=""
dry_run=false
launchctl_bin="${SECURECRT_SYNC_LAUNCHCTL:-launchctl}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      state_path="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$state_path" ]; then
  state_path="$HOME/Library/Application Support/VanDyke/SecureCRT/Setup State/onedrive-sync.plist"
fi
if [ ! -f "$state_path" ]; then
  cat >&2 <<EOF
No SecureCRT setup state was found at:
  $state_path

Run the current setup helper once to create rollback state, then retry.
No settings were changed.
EOF
  exit 1
fi

plist_read() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

case "$(plist_read "$state_path" Version || true)" in
  1|2) ;;
  *)
    echo "Unsupported SecureCRT setup state version: $state_path" >&2
    exit 1
    ;;
esac
if [ "$(plist_read "$state_path" Active || true)" != "true" ]; then
  echo "This computer is already disconnected from SecureCRT OneDrive setup."
  echo "Personal Data was retained at $(plist_read "$state_path" PersonalDataPathInstalled)"
  exit 0
fi

preferences_domain="$(plist_read "$state_path" PreferencesDomain)"
config_before_present="$(plist_read "$state_path" ConfigPathBeforePresent)"
config_before="$(plist_read "$state_path" ConfigPathBefore)"
config_installed="$(plist_read "$state_path" ConfigPathInstalled)"
personal_before_present="$(plist_read "$state_path" PersonalDataPathBeforePresent)"
personal_before="$(plist_read "$state_path" PersonalDataPathBefore)"
personal_installed="$(plist_read "$state_path" PersonalDataPathInstalled)"
store_before_present="$(plist_read "$state_path" StorePersonalDataSeparatelyBeforePresent)"
store_before="$(plist_read "$state_path" StorePersonalDataSeparatelyBefore)"
store_installed="$(plist_read "$state_path" StorePersonalDataSeparatelyInstalled)"
agent_before_present="$(plist_read "$state_path" GuiSshAuthSockBeforePresent)"
agent_before="$(plist_read "$state_path" GuiSshAuthSockBefore)"
agent_installed="$(plist_read "$state_path" GuiSshAuthSockInstalled)"
launch_agent_path="$(plist_read "$state_path" LaunchAgentPath)"
launch_before_present="$(plist_read "$state_path" LaunchAgentBeforePresent)"
launch_before_backup="$(plist_read "$state_path" LaunchAgentBeforeBackupPath)"
launch_installed_hash="$(plist_read "$state_path" LaunchAgentInstalledSha256)"
system_agent_label="$(plist_read "$state_path" SystemSshAgentLabel || true)"
system_agent_disabled_before="$(plist_read "$state_path" SystemSshAgentDisabledBefore || true)"
system_agent_disabled_by_setup="$(plist_read "$state_path" SystemSshAgentDisabledBySetup || true)"

if [ "$launch_before_present" = true ] && [ ! -f "$launch_before_backup" ]; then
  echo "The recorded LaunchAgent backup is missing: $launch_before_backup" >&2
  echo "No settings were changed." >&2
  exit 1
fi

running_clients() {
  pgrep -x SecureCRT >/dev/null 2>&1 || pgrep -x SecureFX >/dev/null 2>&1
}

stop_vandyke_clients() {
  if ! running_clients; then
    return
  fi
  echo "Asking SecureCRT and SecureFX to close..."
  osascript -e 'tell application "SecureCRT" to quit' >/dev/null 2>&1 || true
  osascript -e 'tell application "SecureFX" to quit' >/dev/null 2>&1 || true
  attempts=0
  while running_clients && [ "$attempts" -lt 60 ]; do
    sleep 0.25
    attempts=$((attempts + 1))
  done
  if running_clients; then
    cat >&2 <<'EOF'
SecureCRT or SecureFX did not exit. It may be waiting for confirmation.
Finish closing it, then run disconnect again. No process was force-terminated.
EOF
    exit 1
  fi
}

if [ "$dry_run" = false ]; then
  stop_vandyke_clients
fi

changes=()
skips=()

if defaults read "$preferences_domain" "Config Path" >/dev/null 2>&1; then
  config_current="$(defaults read "$preferences_domain" "Config Path")"
else
  config_current=""
fi
if [ "$config_current" = "$config_installed" ]; then
  changes+=("restore the previous SecureCRT configuration path")
  if [ "$dry_run" = false ]; then
    if [ "$config_before_present" = true ]; then
      defaults write "$preferences_domain" "Config Path" -string "$config_before"
    else
      defaults delete "$preferences_domain" "Config Path" >/dev/null 2>&1 || true
    fi
  fi
else
  skips+=("configuration path changed after setup")
fi

if defaults read "$preferences_domain" "Personal Data Path" >/dev/null 2>&1; then
  personal_current="$(defaults read "$preferences_domain" "Personal Data Path")"
else
  personal_current=""
fi
if [ "$personal_current" = "$personal_installed" ]; then
  changes+=("restore the previous Personal Data path")
  if [ "$dry_run" = false ]; then
    if [ "$personal_before_present" = true ]; then
      defaults write "$preferences_domain" "Personal Data Path" -string "$personal_before"
    else
      defaults delete "$preferences_domain" "Personal Data Path" >/dev/null 2>&1 || true
    fi
  fi
else
  skips+=("Personal Data path changed after setup")
fi

if defaults read "$preferences_domain" "Store Personal Data Separately" >/dev/null 2>&1; then
  store_current="$(defaults read "$preferences_domain" "Store Personal Data Separately")"
else
  store_current=""
fi
if [ "$store_current" = "$store_installed" ]; then
  changes+=("restore the previous Personal Data separation setting")
  if [ "$dry_run" = false ]; then
    if [ "$store_before_present" = true ]; then
      defaults write "$preferences_domain" "Store Personal Data Separately" -int "$store_before"
    else
      defaults delete "$preferences_domain" "Store Personal Data Separately" \
        >/dev/null 2>&1 || true
    fi
  fi
else
  skips+=("Personal Data separation setting changed after setup")
fi

agent_current="$($launchctl_bin getenv SSH_AUTH_SOCK 2>/dev/null || true)"
if [ "$agent_current" = "$agent_installed" ]; then
  changes+=("restore the previous GUI SSH agent environment value")
  if [ "$dry_run" = false ]; then
    if [ "$agent_before_present" = true ]; then
      "$launchctl_bin" setenv SSH_AUTH_SOCK "$agent_before"
    else
      "$launchctl_bin" unsetenv SSH_AUTH_SOCK
    fi
  fi
else
  skips+=("GUI SSH agent environment value changed after setup")
fi

# Setup disables the built-in macOS SSH agent so that its SecureSocketWithKey
# export stops overriding SSH_AUTH_SOCK for GUI applications. Put it back only
# when setup is the one that disabled it.
if [ "$system_agent_disabled_by_setup" = true ] && \
    [ "$system_agent_disabled_before" != true ] && \
    [ -n "$system_agent_label" ]; then
  changes+=("re-enable the built-in macOS SSH agent ($system_agent_label)")
  if [ "$dry_run" = false ]; then
    "$launchctl_bin" enable "gui/$(id -u)/$system_agent_label" \
      >/dev/null 2>&1 || true
  fi
fi

launch_current_hash=""
if [ -f "$launch_agent_path" ]; then
  launch_current_hash="$(shasum -a 256 "$launch_agent_path" | awk '{print $1}')"
fi
if [ -n "$launch_installed_hash" ] && \
    [ "$launch_current_hash" = "$launch_installed_hash" ]; then
  changes+=("restore the previous GUI SSH agent LaunchAgent")
  if [ "$dry_run" = false ]; then
    launch_domain="gui/$(id -u)"
    "$launchctl_bin" bootout "$launch_domain" "$launch_agent_path" >/dev/null 2>&1 || true
    if [ "$launch_before_present" = true ]; then
      cp "$launch_before_backup" "$launch_agent_path"
      chmod 0644 "$launch_agent_path"
      "$launchctl_bin" bootstrap "$launch_domain" "$launch_agent_path"
    else
      rm -f "$launch_agent_path"
    fi
  fi
else
  skips+=("GUI SSH agent LaunchAgent changed after setup")
fi

echo
if [ "$dry_run" = true ]; then
  echo "SecureCRT disconnect dry run:"
else
  echo "SecureCRT disconnected:"
fi
for change in "${changes[@]:-}"; do
  [ -n "$change" ] && echo "  - $change"
done
for skip in "${skips[@]:-}"; do
  [ -n "$skip" ] && echo "  - left unchanged: $skip"
done
echo "  - retained the OneDrive configuration"
echo "  - retained Personal Data at $personal_installed"

if [ "$dry_run" = false ]; then
  state_candidate="$(mktemp "${state_path}.tmp.XXXXXX")"
  cp "$state_path" "$state_candidate"
  /usr/libexec/PlistBuddy -c 'Set :Active false' "$state_candidate"
  disconnected_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! /usr/libexec/PlistBuddy -c "Set :DisconnectedAt $disconnected_at" \
      "$state_candidate" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :DisconnectedAt string $disconnected_at" \
      "$state_candidate"
  fi
  /usr/libexec/PlistBuddy -c "Set :UpdatedAt $disconnected_at" "$state_candidate"
  /usr/bin/plutil -lint "$state_candidate" >/dev/null
  chmod 0600 "$state_candidate"
  mv "$state_candidate" "$state_path"
fi
