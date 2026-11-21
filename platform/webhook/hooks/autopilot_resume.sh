#!/bin/bash

# GET /autopilot_resume?code=<STATUS_CODE>: queue a "resume" for the autopilot; the Mac picks it up
# on its next 15-second report (autopilot_state.sh hands it over once).

[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1
D=/locks/autopilot; mkdir -p "$D" || exit 1
[ -s "$D/commands.json" ] || echo '[]' > "$D/commands.json"
jq -c '. + [{type: "resume"}]' "$D/commands.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/commands.json" || exit 1
echo "Resume queued: the autopilot watches again within ~15 seconds."
