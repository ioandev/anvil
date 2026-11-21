#!/bin/bash

# GET /autopilot_pause?code=<STATUS_CODE>&minutes=N (10-120, default 30): queue a "pause" for the autopilot; the Mac picks it up
# on its next 15-second report (autopilot_state.sh hands it over once).

[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1
D=/locks/autopilot; mkdir -p "$D" || exit 1
[ -s "$D/commands.json" ] || echo '[]' > "$D/commands.json"
m=${minutes:-30}; case "$m" in ''|*[!0-9]*) m=30 ;; esac
[ "$m" -lt 10 ] && m=10; [ "$m" -gt 120 ] && m=120
until=$(date -u -d "@$(( $(date -u +%s) + m * 60 ))" +%Y-%m-%dT%H:%M:%SZ)
jq -c --arg u "$until" '. + [{type: "pause", until: $u}]' "$D/commands.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/commands.json" || exit 1
echo "Pause queued: the autopilot stays off until $until (${m} min). Phone calls are NOT paused (use an Alertmanager silence for that)."
