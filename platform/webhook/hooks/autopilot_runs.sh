#!/bin/bash

# GET /autopilot_runs?code=<STATUS_CODE>: the autopilot's runs, newest first (result, alerts, summary, link).
# GET /autopilot_runs?code=…&id=<run id>: redirects to that run's whole session (secrets scrubbed), served by
# webhook-files at /autopilot-files/<code>/<id>.md (webhookd itself only returns the last 100 lines of output).
# Without the right code: a bare 500. Transcripts kept 90 days (the Mac and the off-site bucket keep them too).

[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1
D=/locks/autopilot/runs
if [ -n "${id:-}" ]; then
  case "$id" in *[!0-9A-Za-z_:.-]*) echo "bad id"; exit 1 ;; esac
  [ -f "$D/$id.md" ] || { echo "no such run: $id"; exit 1; }
  echo "Whole session: $PUBLIC_URL/autopilot-files/$code/$id.md"
  exit 0
fi
ls "$D"/*.json >/dev/null 2>&1 || { echo "No autopilot runs yet."; exit 0; }
echo "Autopilot runs (newest first): each link opens the whole session (secrets scrubbed)."
echo
for j in $(ls -1 "$D"/*.json | sort -r); do
  rid=$(basename "$j" .json)
  jq -r --arg id "$rid" --arg c "$code" --arg u "$PUBLIC_URL" '"\($id)  \(.result // "?" | ascii_upcase)  \((.alerts // []) | map(split("{")[0]) | join(", "))\n  \(.summary // "")\n  \($u)/autopilot-files/\($c)/\($id).md\n"' "$j"
done
