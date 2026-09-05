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
launchd_overrides_plist="${SECURECRT_SYNC_LAUNCHD_OVERRIDES:-/var/db/com.apple.xpc.launchd/disabled.$(id -u).plist}"
launch_agent_label="com.securecrt-config-sync.ssh-agent"
launch_domain="gui/$(id -u)"

pass() { printf '  [ ok ] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; }
info() { printf '         %s\n' "$1"; }

agent_ready=false
agent_disabled_on_disk=false
agent_job_running=false
gui_socket=""
securecrt_socket=""
securecrt_running=false
launch_agent_loaded=false

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
# The override database is the only honest source. "launchctl disable" exits 0
# and "launchctl print-disabled" reports the job as disabled even when the
# write was discarded for lack of root.
if [ -f "$launchd_overrides_plist" ] && \
    [ "$(/usr/libexec/PlistBuddy -c "Print :$system_ssh_agent_label" \
      "$launchd_overrides_plist" 2>/dev/null)" = true ]; then
  agent_disabled_on_disk=true
  pass "disabled in $launchd_overrides_plist"
else
  fail "NOT disabled in $launchd_overrides_plist"
  info "This is the usual cause. An unelevated 'launchctl disable' writes"
  info "nothing to that root-owned file, yet still exits 0."
fi
if "$launchctl_bin" print "$launch_domain/$system_ssh_agent_label" >/dev/null 2>&1; then
  agent_job_running=true
  info "still loaded in this login session"
else
  pass "not loaded in this login session"
fi

echo
echo "Sync LaunchAgent ($launch_agent_label)"
if "$launchctl_bin" print "$launch_domain/$launch_agent_label" >/dev/null 2>&1; then
  launch_agent_loaded=true
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
if [ -z "$gui_socket" ]; then
  fail "SSH_AUTH_SOCK is unset for GUI applications"
elif [ "$gui_socket" = "$onepassword_socket" ]; then
  pass "$gui_socket"
else
  fail "$gui_socket"
  info "That is not the 1Password agent."
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
elif [ "$agent_disabled_on_disk" != true ]; then
  echo "  macOS is overriding SSH_AUTH_SOCK for GUI applications and the"
  echo "  built-in agent is not disabled on disk. Run:"
  echo
  echo "    sudo launchctl disable $launch_domain/$system_ssh_agent_label"
  echo
  echo "  then log out and back in. Confirm it stuck with:"
  echo
  echo "    /usr/libexec/PlistBuddy -c \"Print :$system_ssh_agent_label\" \\"
  echo "      \"$launchd_overrides_plist\""
elif [ "$agent_job_running" = true ] && [ "$gui_socket" != "$onepassword_socket" ]; then
  echo "  The built-in agent is disabled on disk but still loaded in this login"
  echo "  session, so it keeps overriding SSH_AUTH_SOCK. System Integrity"
  echo "  Protection will not let it be unloaded now."
  echo
  echo "  Log out and back in. No reboot is needed."
elif [ "$gui_socket" != "$onepassword_socket" ]; then
  echo "  Nothing is overriding SSH_AUTH_SOCK, but GUI applications are not"
  echo "  receiving the 1Password socket either."
  if [ "$launch_agent_loaded" != true ]; then
    echo "  The sync LaunchAgent is not loaded. Re-run setup-onedrive-macos.sh."
  else
    echo "  Re-run setup-onedrive-macos.sh to reinstall the LaunchAgent."
  fi
elif [ "$securecrt_running" = true ] && [ "$securecrt_socket" != "$onepassword_socket" ]; then
  echo "  The environment is correct, but this SecureCRT was started before it"
  echo "  became correct. Quit SecureCRT and open it again."
else
  echo "  Everything checks out. GUI applications receive the 1Password agent."
  [ "$securecrt_running" = true ] || echo "  Start SecureCRT and connect to a session to confirm."
fi

if [ "$agent_ready" = true ] && [ "$gui_socket" != "$onepassword_socket" ]; then
  cat <<EOF

To use SecureCRT right now, without logging out, start it with the socket set
explicitly. Quit SecureCRT first, then run:

  SSH_AUTH_SOCK="$onepassword_socket" \\
    /Applications/SecureCRT.app/Contents/MacOS/SecureCRT &

Opening it from the Dock will keep prompting until the login session is fixed.
EOF
fi
echo
