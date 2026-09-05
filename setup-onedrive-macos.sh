#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-onedrive-macos.sh [--config PATH] [--personal PATH]
                                 [--preferences-domain DOMAIN] [--state PATH]

Configures SecureCRT to use the synchronized OneDrive configuration while
keeping credentials in a machine-local Personal Data folder. 1Password and
its SSH agent are required for public-key authentication.
EOF
}

config_path=""
personal_path="$HOME/Library/Application Support/VanDyke/SecureCRT/Config.personal"
preferences_domain="com.vandyke.SecureCRT"
state_path=""
onepassword_app="${SECURECRT_SYNC_ONEPASSWORD_APP:-/Applications/1Password.app}"
ssh_agent_socket="${SECURECRT_SYNC_ONEPASSWORD_SOCKET:-$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock}"
launchctl_bin="${SECURECRT_SYNC_LAUNCHCTL:-launchctl}"
system_ssh_agent_label="${SECURECRT_SYNC_SYSTEM_SSH_AGENT:-com.openssh.ssh-agent}"
ssh_agent_relogin_required=unknown
open_bin="${SECURECRT_SYNC_OPEN:-/usr/bin/open}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      config_path="$2"
      shift 2
      ;;
    --personal)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      personal_path="$2"
      shift 2
      ;;
    --preferences-domain)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      preferences_domain="$2"
      shift 2
      ;;
    --state)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      state_path="$2"
      shift 2
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

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
required_helpers=(
  setup-onedrive-macos.sh
  setup-onedrive-windows.ps1
  setup-onedrive-windows.cmd
  disconnect-onedrive-macos.sh
  disconnect-onedrive-windows.ps1
  disconnect-onedrive-windows.cmd
)
for helper in "${required_helpers[@]}"; do
  if [ ! -f "$script_dir/$helper" ]; then
    echo "Required setup helper is missing: $script_dir/$helper" >&2
    echo "Keep all setup-onedrive-* and disconnect-onedrive-* files together, then retry." >&2
    exit 1
  fi
done

onepassword_agent_is_ready() {
  [ -d "$onepassword_app" ] || return 1
  [ -S "$ssh_agent_socket" ] || return 1

  agent_probe_status=0
  SSH_AUTH_SOCK="$ssh_agent_socket" /usr/bin/ssh-add -l >/dev/null 2>&1 || \
    agent_probe_status=$?
  [ "$agent_probe_status" -eq 0 ] || [ "$agent_probe_status" -eq 1 ]
}

wait_for_onepassword_agent() {
  while ! onepassword_agent_is_ready; do
    cat >&2 <<EOF

1Password SSH agent setup is required before SecureCRT can be configured.

1. Install or open 1Password and unlock it.
2. Open Settings > Developer.
3. Enable "Use the SSH Agent".

Expected application: $onepassword_app
Expected agent socket: $ssh_agent_socket
EOF
    if [ -d "$onepassword_app" ] && [ -S "$ssh_agent_socket" ]; then
      echo "The agent socket exists, but it did not respond to an SSH agent probe." >&2
    fi
    if [ ! -t 0 ]; then
      echo "Setup is non-interactive, so it cannot wait for 1Password. Run it from a terminal." >&2
      exit 1
    fi
    printf '\nPress Enter after the 1Password SSH agent is enabled to test again (or Ctrl+C to cancel): ' >&2
    IFS= read -r _
  done
  echo "1Password SSH agent is ready. Continuing setup."
}

wait_for_onepassword_agent

running_clients() {
  pgrep -x SecureCRT >/dev/null 2>&1 || pgrep -x SecureFX >/dev/null 2>&1
}

if running_clients; then
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
Finish closing it, then run setup again. No process was force-terminated.
EOF
    exit 1
  fi
fi

configuration_is_complete() {
  candidate_path="$1"
  [ -f "$candidate_path/Global.ini" ] && [ -d "$candidate_path/Sessions" ]
}

validate_shareable_configuration() {
  candidate_path="$1"
  if ! configuration_is_complete "$candidate_path"; then
    echo "The configuration is incomplete: $candidate_path" >&2
    return 1
  fi

  sensitive_config=false
  while IFS= read -r -d '' session_file; do
    if LC_ALL=C awk '
      {
        sub(/\r$/, "")
        if ($0 ~ /^S:"[^"]*(Password|Passphrase)[^"]*"=.+$/ ||
            $0 == "D:\"Session Password Saved\"=00000001") {
          found = 1
          exit
        }
      }
      END { exit found ? 0 : 1 }
    ' "$session_file"; then
      if [ "$sensitive_config" = false ]; then
        echo "Refusing to share a configuration that may contain saved credentials." >&2
        echo "Move credentials into SecureCRT's Personal Data folder, then retry. Files:" >&2
      fi
      printf '  %s\n' "$session_file" >&2
      sensitive_config=true
    fi
  done < <(find "$candidate_path/Sessions" -type f -name '*.ini' -print0)
  if [ "$sensitive_config" = true ]; then
    return 1
  fi
}

disable_file_backed_ssh_keys() {
  configuration_path="$1"
  ssh2_path="$configuration_path/SSH2.ini"
  [ -f "$ssh2_path" ] || return 0

  temporary_path="$(mktemp "${ssh2_path}.securecrt-config-sync.XXXXXX")"
  skip_lines=0
  changed=false
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line_ending=$'\n'
    line="$raw_line"
    case "$line" in
      *$'\r')
        line="${line%$'\r'}"
        line_ending=$'\r\n'
        ;;
    esac

    if [ "$skip_lines" -gt 0 ]; then
      skip_lines=$((skip_lines - 1))
      changed=true
      continue
    fi

    case "$line" in
      'S:"Identity Filename V2"='*)
        replacement='S:"Identity Filename V2"='
        [ "$line" = "$replacement" ] || changed=true
        printf '%s%s' "$replacement" "$line_ending" >>"$temporary_path"
        ;;
      'D:"Add Private Keys To Agent"='*)
        replacement='D:"Add Private Keys To Agent"=00000000'
        [ "$line" = "$replacement" ] || changed=true
        printf '%s%s' "$replacement" "$line_ending" >>"$temporary_path"
        ;;
      'Z:"Agent Keys To Load"='*)
        key_count_hex="${line#*=}"
        if [[ ! "$key_count_hex" =~ ^[0-9A-Fa-f]{8}$ ]]; then
          rm -f "$temporary_path"
          echo "The SSH agent key list is malformed: $ssh2_path" >&2
          return 1
        fi
        skip_lines=$((16#$key_count_hex))
        replacement='Z:"Agent Keys To Load"=00000000'
        if [ "$line" != "$replacement" ] || [ "$skip_lines" -gt 0 ]; then
          changed=true
        fi
        printf '%s%s' "$replacement" "$line_ending" >>"$temporary_path"
        ;;
      *)
        printf '%s%s' "$line" "$line_ending" >>"$temporary_path"
        ;;
    esac
  done <"$ssh2_path"

  if [ "$skip_lines" -gt 0 ]; then
    rm -f "$temporary_path"
    echo "The SSH agent key list is malformed: $ssh2_path" >&2
    return 1
  fi
  if [ "$changed" = true ]; then
    cp "$temporary_path" "$ssh2_path"
  fi
  rm -f "$temporary_path"
}

migrate_configuration() {
  source_path="$1"
  destination_path="$2"
  destination_parent="$(dirname "$destination_path")"
  mkdir -p "$destination_parent"
  staging_path="$(mktemp -d "$destination_parent/.Config.migration.XXXXXX")"

  if ! /usr/bin/ditto "$source_path" "$staging_path"; then
    rm -rf "$staging_path"
    echo "Could not copy the existing SecureCRT configuration." >&2
    return 1
  fi
  if ! disable_file_backed_ssh_keys "$staging_path"; then
    rm -rf "$staging_path"
    return 1
  fi
  if ! validate_shareable_configuration "$staging_path"; then
    rm -rf "$staging_path"
    return 1
  fi
  if ! mv "$staging_path" "$destination_path"; then
    rm -rf "$staging_path"
    echo "Could not finish the shared SecureCRT configuration migration." >&2
    return 1
  fi

  echo "Migrated the existing SecureCRT configuration:"
  echo "  From: $source_path"
  echo "  To:   $destination_path"
}

if [ -z "$config_path" ]; then
  candidates=()
  if configuration_is_complete "$script_dir/Config"; then
    candidates+=("$script_dir/Config")
  fi
  for candidate in "$HOME"/Library/CloudStorage/OneDrive*/SecureCRT/Config; do
    if configuration_is_complete "$candidate"; then
      duplicate=false
      for existing in "${candidates[@]:-}"; do
        if [ "$existing" = "$candidate" ]; then
          duplicate=true
        fi
      done
      if [ "$duplicate" = false ]; then
        candidates+=("$candidate")
      fi
    fi
  done

  if [ "${#candidates[@]}" -gt 1 ]; then
    echo "More than one SecureCRT configuration was found:" >&2
    printf '  %s\n' "${candidates[@]}" >&2
    echo "Re-run with --config PATH." >&2
    exit 1
  fi
  if [ "${#candidates[@]}" -eq 1 ]; then
    config_path="${candidates[0]}"
  else
    one_drive_roots=()
    for one_drive_root in "$HOME"/Library/CloudStorage/OneDrive*; do
      if [ -d "$one_drive_root" ]; then
        one_drive_roots+=("$one_drive_root")
      fi
    done
    if [ "${#one_drive_roots[@]}" -eq 0 ]; then
      echo "Could not find a OneDrive folder. Use --config PATH." >&2
      exit 1
    fi
    if [ "${#one_drive_roots[@]}" -gt 1 ]; then
      echo "More than one OneDrive folder was found:" >&2
      printf '  %s\n' "${one_drive_roots[@]}" >&2
      echo "Re-run with --config PATH for the new shared Config folder." >&2
      exit 1
    fi
    config_path="${one_drive_roots[0]}/SecureCRT/Config"
  fi
fi

if ! configuration_is_complete "$config_path"; then
  if [ -e "$config_path" ]; then
    echo "The target configuration exists but is incomplete: $config_path" >&2
    echo "Move or repair that folder, then retry; setup will not overwrite it." >&2
    exit 1
  fi

  configured_source="$(defaults read "$preferences_domain" "Config Path" 2>/dev/null || true)"
  default_source="$HOME/Library/Application Support/VanDyke/SecureCRT/Config"
  migration_source=""
  if [ -n "$configured_source" ] && configuration_is_complete "$configured_source"; then
    migration_source="$configured_source"
  elif configuration_is_complete "$default_source"; then
    migration_source="$default_source"
  fi
  if [ -z "$migration_source" ]; then
    cat >&2 <<EOF
The shared configuration does not exist yet, and no existing local SecureCRT
configuration was found to migrate. Expected target: $config_path
EOF
    exit 1
  fi

  migration_source="$(cd "$migration_source" && pwd -P)"
  if ! validate_shareable_configuration "$migration_source"; then
    exit 1
  fi
  if ! migrate_configuration "$migration_source" "$config_path"; then
    exit 1
  fi
fi

validate_shareable_configuration "$config_path"
disable_file_backed_ssh_keys "$config_path"

# Force the essential OneDrive placeholders to hydrate before configuration.
head -c 1 "$config_path/Global.ini" >/dev/null
session_count="$(find "$config_path/Sessions" -type f -name '*.ini' ! -name '__FolderData__.ini' ! -name 'Default.ini' | wc -l | tr -d ' ')"

config_path="$(cd "$config_path" && pwd -P)"
mkdir -p "$personal_path"
personal_path="$(cd "$personal_path" && pwd -P)"

sync_session_usernames() {
  shared_sessions="$1"
  personal_sessions="$2"
  synced=0

  while IFS= read -r -d '' session_file; do
    username="$(LC_ALL=C awk '
      /^S:"Username"=/ {
        sub(/\r$/, "")
        sub(/^S:"Username"=/, "")
        print
        exit
      }
    ' "$session_file")"
    if [ -z "$username" ]; then
      continue
    fi

    relative_path="${session_file#"$shared_sessions"/}"
    personal_file="$personal_sessions/$relative_path"
    mkdir -p "$(dirname "$personal_file")"

    if [ -f "$personal_file" ]; then
      temp_file="$(mktemp "${personal_file}.tmp.XXXXXX")"
      LC_ALL=C awk -v username="$username" '
        BEGIN { replacement = "S:\"Username\"=" username }
        {
          sub(/\r$/, "")
          if ($0 ~ /^S:"Username"=/) {
            if (!found) print replacement
            found = 1
            next
          }
          print
        }
        END { if (!found) print replacement }
      ' ORS='\r\n' "$personal_file" >"$temp_file"
      mv "$temp_file" "$personal_file"
    else
      (
        umask 077
        printf '\357\273\277D:"Session Password Saved"=00000000\r\nS:"Username"=%s\r\n' \
          "$username" >"$personal_file"
      )
    fi
    synced=$((synced + 1))
  done < <(find "$shared_sessions" -type f -name '*.ini' ! -name '__FolderData__.ini' ! -name 'Default.ini' -print0)

  printf '%s' "$synced"
}

synced_username_count="$(sync_session_usernames "$config_path/Sessions" "$personal_path/Sessions")"

xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

plist_read() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

write_setup_state() {
  candidate="$(mktemp "${state_path}.tmp.XXXXXX")"
  escaped_created_at="$(xml_escape "$state_created_at")"
  escaped_updated_at="$(xml_escape "$state_updated_at")"
  escaped_preferences_domain="$(xml_escape "$preferences_domain")"
  escaped_config_before="$(xml_escape "$state_config_before")"
  escaped_config_installed="$(xml_escape "$config_path")"
  escaped_personal_before="$(xml_escape "$state_personal_before")"
  escaped_personal_installed="$(xml_escape "$personal_path")"
  escaped_agent_before="$(xml_escape "$state_agent_before")"
  escaped_agent_installed="$(xml_escape "$ssh_agent_socket")"
  escaped_launch_path="$(xml_escape "$launch_agent_path")"
  escaped_launch_backup="$(xml_escape "$state_launch_before_backup")"
  escaped_launch_hash="$(xml_escape "$state_installed_launch_hash")"
  escaped_system_agent_label="$(xml_escape "$system_ssh_agent_label")"
  config_before_boolean='<false/>'
  personal_before_boolean='<false/>'
  store_before_boolean='<false/>'
  agent_before_boolean='<false/>'
  launch_before_boolean='<false/>'
  system_agent_before_boolean='<false/>'
  system_agent_disabled_boolean='<false/>'
  [ "$state_config_before_present" = true ] && config_before_boolean='<true/>'
  [ "$state_personal_before_present" = true ] && personal_before_boolean='<true/>'
  [ "$state_store_before_present" = true ] && store_before_boolean='<true/>'
  [ "$state_agent_before_present" = true ] && agent_before_boolean='<true/>'
  [ "$state_launch_before_present" = true ] && launch_before_boolean='<true/>'
  [ "$state_system_agent_disabled_before" = true ] && system_agent_before_boolean='<true/>'
  [ "$state_system_agent_disabled_by_setup" = true ] && system_agent_disabled_boolean='<true/>'

  cat >"$candidate" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Version</key><integer>2</integer>
  <key>Active</key><true/>
  <key>CreatedAt</key><string>$escaped_created_at</string>
  <key>UpdatedAt</key><string>$escaped_updated_at</string>
  <key>PreferencesDomain</key><string>$escaped_preferences_domain</string>
  <key>ConfigPathBeforePresent</key>$config_before_boolean
  <key>ConfigPathBefore</key><string>$escaped_config_before</string>
  <key>ConfigPathInstalled</key><string>$escaped_config_installed</string>
  <key>PersonalDataPathBeforePresent</key>$personal_before_boolean
  <key>PersonalDataPathBefore</key><string>$escaped_personal_before</string>
  <key>PersonalDataPathInstalled</key><string>$escaped_personal_installed</string>
  <key>StorePersonalDataSeparatelyBeforePresent</key>$store_before_boolean
  <key>StorePersonalDataSeparatelyBefore</key><integer>$state_store_before</integer>
  <key>StorePersonalDataSeparatelyInstalled</key><integer>1</integer>
  <key>GuiSshAuthSockBeforePresent</key>$agent_before_boolean
  <key>GuiSshAuthSockBefore</key><string>$escaped_agent_before</string>
  <key>GuiSshAuthSockInstalled</key><string>$escaped_agent_installed</string>
  <key>LaunchAgentPath</key><string>$escaped_launch_path</string>
  <key>LaunchAgentBeforePresent</key>$launch_before_boolean
  <key>LaunchAgentBeforeBackupPath</key><string>$escaped_launch_backup</string>
  <key>LaunchAgentInstalledSha256</key><string>$escaped_launch_hash</string>
  <key>SystemSshAgentLabel</key><string>$escaped_system_agent_label</string>
  <key>SystemSshAgentDisabledBefore</key>$system_agent_before_boolean
  <key>SystemSshAgentDisabledBySetup</key>$system_agent_disabled_boolean
</dict>
</plist>
EOF
  /usr/bin/plutil -lint "$candidate" >/dev/null
  chmod 0600 "$candidate"
  mv "$candidate" "$state_path"
}

launch_agent_label="com.securecrt-config-sync.ssh-agent"
launch_agent_dir="$HOME/Library/LaunchAgents"
launch_agent_path="$launch_agent_dir/$launch_agent_label.plist"
if [ -z "$state_path" ]; then
  state_path="$HOME/Library/Application Support/VanDyke/SecureCRT/Setup State/onedrive-sync.plist"
fi
state_dir="$(dirname "$state_path")"
mkdir -p "$state_dir"
state_path="$(cd "$state_dir" && pwd -P)/$(basename "$state_path")"
state_launch_before_backup="$state_dir/launch-agent-before.plist"

if defaults read "$preferences_domain" "Config Path" >/dev/null 2>&1; then
  old_config_present=true
  old_config="$(defaults read "$preferences_domain" "Config Path")"
else
  old_config_present=false
  old_config=""
fi
if defaults read "$preferences_domain" "Personal Data Path" >/dev/null 2>&1; then
  old_personal_present=true
  old_personal="$(defaults read "$preferences_domain" "Personal Data Path")"
else
  old_personal_present=false
  old_personal=""
fi
if defaults read "$preferences_domain" "Store Personal Data Separately" >/dev/null 2>&1; then
  old_store_personal_present=true
  old_store_personal="$(defaults read "$preferences_domain" "Store Personal Data Separately")"
else
  old_store_personal_present=false
  old_store_personal="0"
fi
old_agent_socket="$($launchctl_bin getenv SSH_AUTH_SOCK 2>/dev/null || true)"

state_is_active=false
state_installed_launch_hash=""
if [ -f "$state_path" ]; then
  state_version="$(plist_read "$state_path" Version || true)"
  case "$state_version" in
    1|2) ;;
    *)
      echo "Unsupported SecureCRT setup state version: $state_path" >&2
      exit 1
      ;;
  esac
  if [ "$(plist_read "$state_path" Active || true)" = "true" ]; then
    state_is_active=true
  fi
fi

if [ "$state_is_active" = true ]; then
  state_created_at="$(plist_read "$state_path" CreatedAt)"
  state_config_before_present="$(plist_read "$state_path" ConfigPathBeforePresent)"
  state_config_before="$(plist_read "$state_path" ConfigPathBefore)"
  state_personal_before_present="$(plist_read "$state_path" PersonalDataPathBeforePresent)"
  state_personal_before="$(plist_read "$state_path" PersonalDataPathBefore)"
  state_store_before_present="$(plist_read "$state_path" StorePersonalDataSeparatelyBeforePresent)"
  state_store_before="$(plist_read "$state_path" StorePersonalDataSeparatelyBefore)"
  state_agent_before_present="$(plist_read "$state_path" GuiSshAuthSockBeforePresent)"
  state_agent_before="$(plist_read "$state_path" GuiSshAuthSockBefore)"
  state_launch_before_present="$(plist_read "$state_path" LaunchAgentBeforePresent)"
  state_launch_before_backup="$(plist_read "$state_path" LaunchAgentBeforeBackupPath)"
  state_installed_launch_hash="$(plist_read "$state_path" LaunchAgentInstalledSha256)"
  state_system_agent_disabled_before="$(plist_read "$state_path" SystemSshAgentDisabledBefore || true)"
  if [ -n "$state_system_agent_disabled_before" ]; then
    state_system_agent_before_present=true
  else
    state_system_agent_before_present=false
    state_system_agent_disabled_before=false
  fi
  state_system_agent_disabled_by_setup="$(plist_read "$state_path" SystemSshAgentDisabledBySetup || true)"
  [ -n "$state_system_agent_disabled_by_setup" ] || state_system_agent_disabled_by_setup=false
else
  state_created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_config_before_present="$old_config_present"
  state_config_before="$old_config"
  state_personal_before_present="$old_personal_present"
  state_personal_before="$old_personal"
  state_store_before_present="$old_store_personal_present"
  state_store_before="$old_store_personal"
  state_agent_before_present=false
  state_agent_before="$old_agent_socket"
  [ -n "$old_agent_socket" ] && state_agent_before_present=true
  state_launch_before_present=false
  state_system_agent_before_present=false
  state_system_agent_disabled_before=false
  state_system_agent_disabled_by_setup=false

  looks_like_legacy_install=false
  if [ "$old_config" = "$config_path" ] && [ "$old_personal" = "$personal_path" ] && \
      [ "$old_store_personal" = "1" ] && [ "$old_agent_socket" = "$ssh_agent_socket" ]; then
    looks_like_legacy_install=true
  fi

  backup_dir="$HOME/Library/Application Support/VanDyke/SecureCRT/Setup Backups"
  latest_path_backup=""
  if [ -d "$backup_dir" ]; then
    newest_path_backup=""
    while IFS= read -r candidate_path_backup; do
      [ -n "$newest_path_backup" ] || newest_path_backup="$candidate_path_backup"
      candidate_previous_config="$(sed -n 's/^Config Path=//p' "$candidate_path_backup")"
      if [ "$candidate_previous_config" != "$config_path" ]; then
        latest_path_backup="$candidate_path_backup"
        break
      fi
    done < <(find "$backup_dir" -maxdepth 1 -type f \
      -name 'configuration-paths-*.txt' -print | sort -r)
    [ -n "$latest_path_backup" ] || latest_path_backup="$newest_path_backup"
  fi
  if [ "$looks_like_legacy_install" = true ] && [ -n "$latest_path_backup" ]; then
    state_config_before="$(sed -n 's/^Config Path=//p' "$latest_path_backup")"
    state_personal_before="$(sed -n 's/^Personal Data Path=//p' "$latest_path_backup")"
    state_store_before="$(sed -n 's/^Store Personal Data Separately=//p' "$latest_path_backup")"
    state_config_before_present=false
    state_personal_before_present=false
    state_store_before_present=false
    [ -n "$state_config_before" ] && state_config_before_present=true
    [ -n "$state_personal_before" ] && state_personal_before_present=true
    [ -n "$state_store_before" ] && state_store_before_present=true
  fi
  default_local_config="$HOME/Library/Application Support/VanDyke/SecureCRT/Config"
  if [ "$looks_like_legacy_install" = true ] && \
      [ "$state_config_before" = "$config_path" ] && \
      configuration_is_complete "$default_local_config"; then
    default_local_config="$(cd "$default_local_config" && pwd -P)"
    state_config_before_present=true
    state_config_before="$default_local_config"
    state_personal_before_present=false
    state_personal_before=""
    state_store_before_present=false
    state_store_before="0"
    state_agent_before_present=false
    state_agent_before=""
  fi

  if [ -f "$launch_agent_path" ]; then
    if [ "$looks_like_legacy_install" = true ] && \
        grep -Fq "<string>$launch_agent_label</string>" "$launch_agent_path"; then
      latest_launch_backup=""
      if [ -d "$backup_dir" ]; then
        latest_launch_backup="$(find "$backup_dir" -maxdepth 1 -type f \
          -name 'ssh-agent-launch-agent-*.plist' -print | sort | tail -n 1)"
      fi
      if [ -n "$latest_launch_backup" ]; then
        cp "$latest_launch_backup" "$state_launch_before_backup"
        state_launch_before_present=true
      fi
    else
      cp "$launch_agent_path" "$state_launch_before_backup"
      state_launch_before_present=true
    fi
  fi
  if [ "$looks_like_legacy_install" = true ] && [ "$old_agent_socket" = "$ssh_agent_socket" ]; then
    state_agent_before_present=false
    state_agent_before=""
  fi
fi

state_updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_setup_state

launch_domain="gui/$(id -u)"

# macOS ships /System/Library/LaunchAgents/com.openssh.ssh-agent.plist, whose
# Sockets > Listeners > SecureSocketWithKey entry tells launchd to publish the
# built-in agent's socket as SSH_AUTH_SOCK. launchd injects that value into
# every application started through Launch Services, and the injection wins
# over "launchctl setenv". A GUI SecureCRT therefore talks to the built-in
# agent, which holds no keys, and falls back to password authentication no
# matter what this script sets. Note that "launchctl getenv" still reports the
# value set below, so it cannot be used to verify the result.
system_ssh_agent_is_disabled() {
  disabled_line="$("$launchctl_bin" print-disabled "$launch_domain" 2>/dev/null | \
    grep -F "\"$system_ssh_agent_label\"" || true)"
  case "$disabled_line" in
    *disabled*|*true*) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns the SSH_AUTH_SOCK an application launched through Launch Services
# actually inherits, which is the only value that reflects what SecureCRT will
# see. Prints nothing when the probe cannot run, such as on a headless runner.
probe_gui_ssh_auth_sock() {
  probe_root="$(mktemp -d)"
  probe_app="$probe_root/SecureCRTSyncAgentProbe.app"
  probe_out="$probe_root/ssh-auth-sock"
  mkdir -p "$probe_app/Contents/MacOS"
  cat >"$probe_app/Contents/Info.plist" <<'PROBE_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SecureCRTSyncAgentProbe</string>
  <key>CFBundleIdentifier</key><string>io.github.securecrtconfigsync.agentprobe</string>
  <key>CFBundleName</key><string>SecureCRTSyncAgentProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSBackgroundOnly</key><true/>
</dict>
</plist>
PROBE_PLIST
  cat >"$probe_app/Contents/MacOS/SecureCRTSyncAgentProbe" <<PROBE_MAIN
#!/bin/sh
printf '%s' "\${SSH_AUTH_SOCK:-}" >"$probe_out.tmp"
mv "$probe_out.tmp" "$probe_out"
PROBE_MAIN
  chmod 0755 "$probe_app/Contents/MacOS/SecureCRTSyncAgentProbe"

  if "$open_bin" -a "$probe_app" >/dev/null 2>&1; then
    probe_waited=0
    while [ ! -f "$probe_out" ] && [ "$probe_waited" -lt 50 ]; do
      /bin/sleep 0.1
      probe_waited=$((probe_waited + 1))
    done
    [ ! -f "$probe_out" ] || cat "$probe_out"
  fi
  rm -rf "$probe_root"
}

disable_system_ssh_agent() {
  if [ "$state_system_agent_before_present" != true ]; then
    if system_ssh_agent_is_disabled; then
      state_system_agent_disabled_before=true
    else
      state_system_agent_disabled_before=false
    fi
    state_system_agent_before_present=true
  fi

  if system_ssh_agent_is_disabled; then
    return
  fi

  if ! "$launchctl_bin" disable "$launch_domain/$system_ssh_agent_label" \
      >/dev/null 2>&1; then
    echo "Could not disable the built-in macOS SSH agent" \
      "($system_ssh_agent_label)." >&2
    echo "SecureCRT may keep prompting for passwords because macOS overrides" \
      "SSH_AUTH_SOCK for applications started through Launch Services." >&2
    return
  fi
  state_system_agent_disabled_by_setup=true

  # System Integrity Protection refuses to unload the job in the running login
  # session, so the change takes effect at the next login. Try anyway for the
  # case where it is permitted.
  "$launchctl_bin" bootout "$launch_domain/$system_ssh_agent_label" \
    >/dev/null 2>&1 || true
}

configure_gui_ssh_agent() {
  socket_path="$1"
  mkdir -p "$launch_agent_dir"

  escaped_socket="$(xml_escape "$socket_path")"
  candidate="$(mktemp "${launch_agent_path}.tmp.XXXXXX")"
  cat >"$candidate" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$launch_agent_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/launchctl</string>
    <string>setenv</string>
    <string>SSH_AUTH_SOCK</string>
    <string>$escaped_socket</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF
  chmod 0644 "$candidate"

  if [ ! -f "$launch_agent_path" ] || ! cmp -s "$candidate" "$launch_agent_path"; then
    if [ -f "$launch_agent_path" ]; then
      backup_dir="$HOME/Library/Application Support/VanDyke/SecureCRT/Setup Backups"
      mkdir -p "$backup_dir"
      cp "$launch_agent_path" \
        "$backup_dir/ssh-agent-launch-agent-$(date -u +%Y%m%dT%H%M%SZ).plist"
    fi
    mv "$candidate" "$launch_agent_path"
  else
    rm "$candidate"
  fi

  state_installed_launch_hash="$(shasum -a 256 "$launch_agent_path" | awk '{print $1}')"
  state_updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_setup_state

  "$launchctl_bin" bootout "$launch_domain" "$launch_agent_path" >/dev/null 2>&1 || true
  "$launchctl_bin" bootstrap "$launch_domain" "$launch_agent_path"
  "$launchctl_bin" setenv SSH_AUTH_SOCK "$socket_path"
  configured_socket="$($launchctl_bin getenv SSH_AUTH_SOCK)"
  if [ "$configured_socket" != "$socket_path" ]; then
    echo "Could not configure the GUI SSH agent socket." >&2
    exit 1
  fi

  disable_system_ssh_agent

  # "launchctl getenv" reports the value written above even while macOS
  # overrides it for GUI applications, so confirm against what an application
  # started through Launch Services actually inherits.
  gui_socket="$(probe_gui_ssh_auth_sock || true)"
  if [ -z "$gui_socket" ]; then
    ssh_agent_relogin_required=unknown
  elif [ "$gui_socket" = "$socket_path" ]; then
    ssh_agent_relogin_required=false
  else
    ssh_agent_relogin_required=true
  fi
}

configure_gui_ssh_agent "$ssh_agent_socket"
ssh_agent_status="$ssh_agent_socket"
state_installed_launch_hash="$(shasum -a 256 "$launch_agent_path" | awk '{print $1}')"
state_updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_setup_state

if [ "$old_config" != "$config_path" ] || [ "$old_personal" != "$personal_path" ] || \
    [ "$old_store_personal" != "1" ]; then
  backup_dir="$HOME/Library/Application Support/VanDyke/SecureCRT/Setup Backups"
  mkdir -p "$backup_dir"
  backup_path="$backup_dir/configuration-paths-$(date -u +%Y%m%dT%H%M%SZ).txt"
  {
    printf 'Config Path=%s\n' "$old_config"
    printf 'Personal Data Path=%s\n' "$old_personal"
    printf 'Store Personal Data Separately=%s\n' "$old_store_personal"
  } >"$backup_path"
  echo "Backed up the previous path settings to $backup_path"
fi

defaults write "$preferences_domain" "Config Path" -string "$config_path"
defaults write "$preferences_domain" "Personal Data Path" -string "$personal_path"
defaults write "$preferences_domain" "Store Personal Data Separately" -bool true

configured_config="$(defaults read "$preferences_domain" "Config Path")"
configured_personal="$(defaults read "$preferences_domain" "Personal Data Path")"
configured_store_personal="$(defaults read "$preferences_domain" "Store Personal Data Separately")"
if [ "$configured_config" != "$config_path" ] || \
    [ "$configured_personal" != "$personal_path" ] || \
    [ "$configured_store_personal" != "1" ]; then
  echo "SecureCRT preference verification failed." >&2
  exit 1
fi

# Put both platform setup helpers next to Config so they arrive through
# OneDrive. If this script is already running there, no copy is needed.
securecrt_root="$(dirname "$config_path")"
for helper in "${required_helpers[@]}"; do
  source_path="$script_dir/$helper"
  target_path="$securecrt_root/$helper"
  if [ -f "$source_path" ] && [ "$source_path" != "$target_path" ]; then
    cp "$source_path" "$target_path"
  fi
done
chmod 0755 "$securecrt_root/setup-onedrive-macos.sh"
chmod 0755 "$securecrt_root/disconnect-onedrive-macos.sh"

cat <<EOF

SecureCRT OneDrive setup is complete.
  Shared configuration: $config_path
  Local personal data:  $personal_path
  Saved sessions:        $session_count
  Synced usernames:      $synced_username_count
  External SSH agent:    $ssh_agent_status
  Disconnect state:      $state_path

The Windows one-click setup is now available at:
  $securecrt_root/setup-onedrive-windows.cmd
EOF

case "$ssh_agent_relogin_required" in
  true)
    cat <<EOF

Log out and back in before starting SecureCRT.

macOS is still publishing its own SSH_AUTH_SOCK to applications started
through Launch Services, which hides the 1Password agent and makes SecureCRT
fall back to password prompts. The built-in agent ($system_ssh_agent_label) has
been disabled for this user, but System Integrity Protection does not allow
unloading it from the running login session.
EOF
    ;;
  unknown)
    cat <<EOF

The GUI SSH agent socket could not be verified automatically. If SecureCRT
prompts for a password, log out and back in, then try again.
EOF
    ;;
esac
