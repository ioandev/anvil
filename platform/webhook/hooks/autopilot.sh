#!/bin/bash

# GET /autopilot?code=<STATUS_CODE>: the autopilot's state (as the Mac last reported it), plus the owner's links.

[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1
D=/locks/autopilot
[ -s "$D/state.json" ] || { echo "The autopilot hasn't reported yet."; exit 0; }
now=$(date -u +%s)
jq -r --argjson now "$now" --arg c "$code" --arg u "$PUBLIC_URL" '
  "Autopilot: \(.state | ascii_upcase) since \(.since // "?")",
  (if .paused_until then "Paused until \(.paused_until)" else empty end),
  "Last heartbeat: \($now - .received)s ago\(if ($now - .received) > 120 then "  (!! the Mac may be offline)" else "" end)",
  "Runs today: \(.runs_today // 0)/\(.max_runs_per_day // "?")   total: \(.runs_total // 0)   version: \(.version // "?")",
  "",
  (if (.incident.alerts // []) | length > 0 then "Current incident (since \(.incident.first_bad // "?")):", (.incident.alerts[] | "  - \(.)") else "No incident." end),
  "",
  (if .last_run then
     "Last run: \(.last_run.result // "running") · started \(.last_run.started) · finished \(.last_run.finished // "-")",
     "  \(.last_run.summary // "")",
     "  Full record: \(.last_run.record // "-")"
   else "No runs yet." end),
  "",
  "Re-arm now:  \($u)/autopilot_reset?code=\($c)",
  "Pause:       \($u)/autopilot_pause?code=\($c)&minutes=30   (10-120)",
  "Resume:      \($u)/autopilot_resume?code=\($c)",
  "History:     \($u)/changelog?code=\($c)",
  "Sessions:    \($u)/autopilot_runs?code=\($c)"' "$D/state.json"
