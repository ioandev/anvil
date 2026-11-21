#!/bin/bash

# GET /autopilot_reset?code=<STATUS_CODE>: queue a "reset" for the autopilot; the Mac picks it up
# on its next 15-second report (autopilot_state.sh hands it over once).

[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1
D=/locks/autopilot; mkdir -p "$D" || exit 1
[ -s "$D/commands.json" ] || echo '[]' > "$D/commands.json"
jq -c '. + [{type: "reset"}]' "$D/commands.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/commands.json" || exit 1
echo "Reset queued: the autopilot re-arms within ~15 seconds (if the Mac is online). Status: /autopilot?code=…"
