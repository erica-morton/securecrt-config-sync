#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-onedrive-macos.sh [--config PATH] [--personal PATH]
                                 [--preferences-domain DOMAIN]

Configures SecureCRT to use the synchronized OneDrive configuration while
keeping credentials in a machine-local Personal Data folder. 1Password and
its SSH agent are required for public-key authentication.
EOF
}

config_path=""
personal_path="$HOME/Library/Application Support/VanDyke/SecureCRT/Config.personal"
preferences_domain="com.vandyke.SecureCRT"
onepassword_app="${SECURECRT_SYNC_ONEPASSWORD_APP:-/Applications/1Password.app}"
ssh_agent_socket="${SECURECRT_SYNC_ONEPASSWORD_SOCKET:-$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock}"
launchctl_bin="${SECURECRT_SYNC_LAUNCHCTL:-launchctl}"

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
)
for helper in "${required_helpers[@]}"; do
  if [ ! -f "$script_dir/$helper" ]; then
    echo "Required setup helper is missing: $script_dir/$helper" >&2
    echo "Keep all three setup-onedrive-* files together, then retry." >&2
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

configure_gui_ssh_agent() {
  socket_path="$1"
  launch_agent_label="com.securecrt-config-sync.ssh-agent"
  launch_agent_dir="$HOME/Library/LaunchAgents"
  launch_agent_path="$launch_agent_dir/$launch_agent_label.plist"
  mkdir -p "$launch_agent_dir"

  escaped_socket="$(printf '%s' "$socket_path" | sed \
    -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
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

  launch_domain="gui/$(id -u)"
  "$launchctl_bin" bootout "$launch_domain" "$launch_agent_path" >/dev/null 2>&1 || true
  "$launchctl_bin" bootstrap "$launch_domain" "$launch_agent_path"
  "$launchctl_bin" setenv SSH_AUTH_SOCK "$socket_path"
  configured_socket="$($launchctl_bin getenv SSH_AUTH_SOCK)"
  if [ "$configured_socket" != "$socket_path" ]; then
    echo "Could not configure the GUI SSH agent socket." >&2
    exit 1
  fi
}

configure_gui_ssh_agent "$ssh_agent_socket"
ssh_agent_status="$ssh_agent_socket"

old_config="$(defaults read "$preferences_domain" "Config Path" 2>/dev/null || true)"
old_personal="$(defaults read "$preferences_domain" "Personal Data Path" 2>/dev/null || true)"
old_store_personal="$(defaults read "$preferences_domain" "Store Personal Data Separately" 2>/dev/null || true)"
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

cat <<EOF

SecureCRT OneDrive setup is complete.
  Shared configuration: $config_path
  Local personal data:  $personal_path
  Saved sessions:        $session_count
  Synced usernames:      $synced_username_count
  External SSH agent:    $ssh_agent_status

The Windows one-click setup is now available at:
  $securecrt_root/setup-onedrive-windows.cmd
EOF
