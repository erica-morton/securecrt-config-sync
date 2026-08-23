#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-onedrive-macos.sh [--config PATH] [--personal PATH]
                                 [--preferences-domain DOMAIN]

Configures SecureCRT to use the synchronized OneDrive configuration while
keeping credentials in a machine-local Personal Data folder.
EOF
}

config_path=""
personal_path="$HOME/Library/Application Support/VanDyke/SecureCRT/Config.personal"
preferences_domain="com.vandyke.SecureCRT"

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

script_dir="$(cd "$(dirname "$0")" && pwd -P)"

if [ -z "$config_path" ]; then
  candidates=()
  if [ -f "$script_dir/Config/Global.ini" ] && [ -d "$script_dir/Config/Sessions" ]; then
    candidates+=("$script_dir/Config")
  fi
  for candidate in "$HOME"/Library/CloudStorage/OneDrive*/SecureCRT/Config; do
    if [ -f "$candidate/Global.ini" ] && [ -d "$candidate/Sessions" ]; then
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

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo "Could not find OneDrive/SecureCRT/Config. Use --config PATH." >&2
    exit 1
  fi
  if [ "${#candidates[@]}" -gt 1 ]; then
    echo "More than one SecureCRT configuration was found:" >&2
    printf '  %s\n' "${candidates[@]}" >&2
    echo "Re-run with --config PATH." >&2
    exit 1
  fi
  config_path="${candidates[0]}"
fi

if [ ! -f "$config_path/Global.ini" ] || [ ! -d "$config_path/Sessions" ]; then
  echo "The configuration is incomplete: $config_path" >&2
  exit 1
fi

sensitive_config=false
while IFS= read -r -d '' session_file; do
  if LC_ALL=C grep -Eq 'S:"[^"]*(Password|Passphrase)[^"]*"=.+$|D:"Session Password Saved"=00000001$' "$session_file"; then
    if [ "$sensitive_config" = false ]; then
      echo "Refusing to share a configuration that may contain saved credentials." >&2
      echo "Move credentials into SecureCRT's Personal Data folder, then retry. Files:" >&2
    fi
    printf '  %s\n' "$session_file" >&2
    sensitive_config=true
  fi
done < <(find "$config_path/Sessions" -type f -name '*.ini' -print0)
if [ "$sensitive_config" = true ]; then
  exit 1
fi

# Force the essential OneDrive placeholders to hydrate before configuration.
head -c 1 "$config_path/Global.ini" >/dev/null
session_count="$(find "$config_path/Sessions" -type f -name '*.ini' ! -name '__FolderData__.ini' ! -name 'Default.ini' | wc -l | tr -d ' ')"

config_path="$(cd "$config_path" && pwd -P)"
mkdir -p "$personal_path"
personal_path="$(cd "$personal_path" && pwd -P)"

old_config="$(defaults read "$preferences_domain" "Config Path" 2>/dev/null || true)"
old_personal="$(defaults read "$preferences_domain" "Personal Data Path" 2>/dev/null || true)"
if [ "$old_config" != "$config_path" ] || [ "$old_personal" != "$personal_path" ]; then
  backup_dir="$HOME/Library/Application Support/VanDyke/SecureCRT/Setup Backups"
  mkdir -p "$backup_dir"
  backup_path="$backup_dir/configuration-paths-$(date -u +%Y%m%dT%H%M%SZ).txt"
  {
    printf 'Config Path=%s\n' "$old_config"
    printf 'Personal Data Path=%s\n' "$old_personal"
  } >"$backup_path"
  echo "Backed up the previous path settings to $backup_path"
fi

defaults write "$preferences_domain" "Config Path" -string "$config_path"
defaults write "$preferences_domain" "Personal Data Path" -string "$personal_path"

configured_config="$(defaults read "$preferences_domain" "Config Path")"
configured_personal="$(defaults read "$preferences_domain" "Personal Data Path")"
if [ "$configured_config" != "$config_path" ] || [ "$configured_personal" != "$personal_path" ]; then
  echo "SecureCRT preference verification failed." >&2
  exit 1
fi

# Put both platform setup helpers next to Config so they arrive through
# OneDrive. If this script is already running there, no copy is needed.
securecrt_root="$(dirname "$config_path")"
for helper in setup-onedrive-macos.sh setup-onedrive-windows.ps1 setup-onedrive-windows.cmd; do
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

The Windows one-click setup is now available at:
  $securecrt_root/setup-onedrive-windows.cmd
EOF
