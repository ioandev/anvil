#!/bin/bash
# Schedules pull.sh: every hour with --daily, so it runs once a day and a machine that was off catches up when it's
# back. Linux: a systemd user timer (Persistent), or a crontab line where there's no systemd. macOS: a launchd agent.
#   ./install.sh            install (idempotent)
#   ./install.sh remove     uninstall
set -euo pipefail
cd "$(dirname "$0")"; HERE="$(pwd)"
[ -f .env ] || { echo "create .env first (cp .env.example .env; chmod 600 .env; fill it in)"; exit 1; }
chmod 600 .env; chmod +x pull.sh
NAME=${ANVIL_NAME:-anvil}-backup-pull
if [ "$(uname)" = Darwin ]; then
  P="$HOME/Library/LaunchAgents/com.anvil.$NAME.plist"
  launchctl unload "$P" 2>/dev/null || true
  if [ "${1:-}" = remove ]; then rm -f "$P"; echo "removed"; exit 0; fi
  mkdir -p "$(dirname "$P")"
  cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.anvil.$NAME</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$HERE/pull.sh</string><string>--daily</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
  launchctl load "$P"; echo "installed: launchd agent com.anvil.$NAME (hourly check, runs once a day)"
elif systemctl --user show-environment >/dev/null 2>&1; then
  U="$HOME/.config/systemd/user"; mkdir -p "$U"
  if [ "${1:-}" = remove ]; then systemctl --user disable --now "$NAME.timer" 2>/dev/null || true; rm -f "$U/$NAME".{service,timer}; systemctl --user daemon-reload; echo "removed"; exit 0; fi
  cat > "$U/$NAME.service" <<SV
[Unit]
Description=Local copy of the server's databases ($HERE/pull.sh)
[Service]
Type=oneshot
ExecStart=/bin/bash $HERE/pull.sh --daily
SV
  cat > "$U/$NAME.timer" <<TM
[Unit]
Description=Hourly check; pull.sh runs once a day
[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true
[Install]
WantedBy=timers.target
TM
  systemctl --user daemon-reload; systemctl --user enable --now "$NAME.timer"
  loginctl enable-linger "$USER" 2>/dev/null || echo "note: without 'loginctl enable-linger $USER' it runs only while you're logged in"
  echo "installed: systemd user timer $NAME.timer (hourly check, runs once a day)"
else
  line="17 * * * * /bin/bash $HERE/pull.sh --daily # $NAME"
  { crontab -l 2>/dev/null | grep -v "# $NAME\$" || true; [ "${1:-}" = remove ] || echo "$line"; } | crontab -
  [ "${1:-}" = remove ] && echo "removed" || echo "installed: crontab line (hourly check, runs once a day)"
fi
