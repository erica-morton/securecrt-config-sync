#!/usr/bin/env bash
# Diagnoses why SecureCRT prompts for a password instead of authenticating
# through the 1Password SSH agent. Read-only: it reports and recommends, and
# changes nothing.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: diagnose-ssh-agent-macos.sh

Checks each link between the 1Password SSH agent and a GUI SecureCRT, then
prints a diagnosis and the exact command to fix it. Changes nothing.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

onepassword_socket="${SECURECRT_SYNC_ONEPASSWORD_SOCKET:-$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock}"
system_ssh_agent_label="${SECURECRT_SYNC_SYSTEM_SSH_AGENT:-com.openssh.ssh-agent}"
launchctl_bin="${SECURECRT_SYNC_LAUNCHCTL:-launchctl}"
open_bin="${SECURECRT_SYNC_OPEN:-/usr/bin/open}"
launch_agent_label="com.securecrt-config-sync.ssh-agent"
launch_domain="gui/$(id -u)"
securecrt_app="${SECURECRT_SYNC_SECURECRT_APP:-/Applications/SecureCRT.app}"
launcher_app="${SECURECRT_SYNC_LAUNCHER_APP:-$HOME/Applications/SecureCRT (1Password).app}"

pass() { printf '  [ ok ] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; }
info() { printf '         %s\n' "$1"; }

agent_ready=false
launcher_ok=false
gui_socket=""
securecrt_socket=""
securecrt_running=false

echo
echo "1Password SSH agent"
if [ ! -S "$onepassword_socket" ]; then
  fail "no agent socket at $onepassword_socket"
  info "Open 1Password and enable Settings > Developer > Use the SSH Agent."
else
  key_list="$(SSH_AUTH_SOCK="$onepassword_socket" /usr/bin/ssh-add -l 2>&1)"
  probe_status=$?
  if [ "$probe_status" -eq 0 ]; then
    agent_ready=true
    pass "responding with $(printf '%s\n' "$key_list" | grep -c .) key(s)"
  elif [ "$probe_status" -eq 1 ]; then
    agent_ready=true
    fail "agent is reachable but holds no keys"
  else
    fail "socket exists but did not respond: $key_list"
  fi
fi

echo
echo "Built-in macOS SSH agent ($system_ssh_agent_label)"
if "$launchctl_bin" print "$launch_domain/$system_ssh_agent_label" >/dev/null 2>&1; then
  info "loaded - it is publishing SSH_AUTH_SOCK to GUI applications"
else
  info "not loaded in this login session"
fi
info "This is expected and is not the thing to fix. Disabling it needs root"
info "and does not survive a reboot: macOS rewrites the override database at"
info "boot and drops the entry for this SIP-protected job. Use the launcher."

echo
echo "SecureCRT agent launcher"
launcher_exec="$launcher_app/Contents/MacOS/launcher"
if [ ! -e "$launcher_app" ]; then
  fail "not installed at $launcher_app"
  info "Run setup-onedrive-macos.sh to create it."
elif [ ! -x "$launcher_exec" ]; then
  fail "$launcher_app exists but $launcher_exec is not executable"
elif ! grep -Fq "$onepassword_socket" "$launcher_exec"; then
  fail "launcher does not reference $onepassword_socket"
  info "Re-run setup-onedrive-macos.sh to regenerate it."
elif ! grep -Fq "$securecrt_app/Contents/MacOS/SecureCRT" "$launcher_exec"; then
  fail "launcher does not exec $securecrt_app/Contents/MacOS/SecureCRT"
  info "Re-run setup-onedrive-macos.sh to regenerate it."
elif [ ! -x "$securecrt_app/Contents/MacOS/SecureCRT" ]; then
  fail "launcher points at $securecrt_app/Contents/MacOS/SecureCRT, which is missing"
  info "Install SecureCRT there, or re-run setup with"
  info "SECURECRT_SYNC_SECURECRT_APP set to its real location."
else
  launcher_ok=true
  pass "$launcher_app"
fi

echo
echo "Sync LaunchAgent ($launch_agent_label)"
if "$launchctl_bin" print "$launch_domain/$launch_agent_label" >/dev/null 2>&1; then
  pass "loaded"
else
  fail "not loaded - run setup-onedrive-macos.sh"
fi
info "launchctl getenv reports: $("$launchctl_bin" getenv SSH_AUTH_SOCK 2>/dev/null || echo '<unset>')"
info "(that is the value that was set, not the one GUI apps receive)"

echo
echo "What a Dock-launched application actually inherits"
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
  [ ! -f "$probe_out" ] || gui_socket="$(cat "$probe_out")"
fi
rm -rf "$probe_root"
if [ "$gui_socket" = "$onepassword_socket" ]; then
  pass "$gui_socket"
elif [ "$launcher_ok" = true ]; then
  info "${gui_socket:-<unset>}"
  info "Not the 1Password agent, which is normal on a SIP-enabled Mac and is"
  info "exactly what the launcher exists to bypass."
elif [ -z "$gui_socket" ]; then
  fail "SSH_AUTH_SOCK is unset for GUI applications"
else
  fail "$gui_socket"
  info "That is not the 1Password agent, and no launcher is installed."
fi

echo
echo "Running SecureCRT"
securecrt_pid="$(pgrep -x SecureCRT | head -1)"
if [ -z "$securecrt_pid" ]; then
  info "not running"
else
  securecrt_running=true
  # A socket path can contain spaces, so split on VAR= rather than on spaces.
  securecrt_socket="$(ps eww -p "$securecrt_pid" 2>/dev/null | \
    sed 's/ \([A-Za-z_][A-Za-z0-9_]*\)=/\n\1=/g' | \
    sed -n 's/^SSH_AUTH_SOCK=//p' | head -1)"
  if [ "$securecrt_socket" = "$onepassword_socket" ]; then
    pass "pid $securecrt_pid is using the 1Password agent"
  else
    fail "pid $securecrt_pid has SSH_AUTH_SOCK=${securecrt_socket:-<unset>}"
  fi
fi

echo
echo "Diagnosis"
if [ "$agent_ready" != true ]; then
  echo "  The 1Password agent is not usable. Fix that first: open 1Password,"
  echo "  unlock it, and enable Settings > Developer > Use the SSH Agent."
elif [ "$launcher_ok" != true ]; then
  echo "  The launcher is missing or stale, and macOS is handing GUI"
  echo "  applications its own SSH_AUTH_SOCK. Re-run setup:"
  echo
  echo "    bash ./setup-onedrive-macos.sh"
elif [ "$securecrt_running" != true ]; then
  echo "  Everything needed is in place. Start SecureCRT from:"
  echo
  echo "    $launcher_app"
  echo
  echo "  then connect to a session to confirm."
elif [ "$securecrt_socket" = "$onepassword_socket" ]; then
  echo "  All good. This SecureCRT is using the 1Password agent."
  if [ "$gui_socket" != "$onepassword_socket" ]; then
    echo "  Keep starting it from the launcher - opening"
    echo "  $(basename "$securecrt_app") directly will prompt for passwords."
  fi
else
  echo "  This SecureCRT was started directly rather than through the"
  echo "  launcher, so it inherited macOS's own SSH_AUTH_SOCK. Quit it and"
  echo "  open:"
  echo
  echo "    $launcher_app"
  echo
  echo "  Drag that into the Dock and remove the old SecureCRT tile so the"
  echo "  wrong one is not one click away."
fi

if [ "$agent_ready" = true ] && [ "$launcher_ok" = true ] && \
    [ "$securecrt_socket" != "$onepassword_socket" ]; then
  cat <<EOF

To start it from a terminal instead:

  open -a "$launcher_app"
EOF
fi
echo
