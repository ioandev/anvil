#!/bin/bash

# POST /autopilot_state (header X-Token): the autopilot on the Mac reports its state every 15 s (body: see
# docs/autopilot-interfaces.md). Stored in /locks/autopilot/state.json with the time received. Answers with the owner's
# queued commands (reset / pause / resume, from the GET links), once. Tells twilio-alert when a run starts (hold the
# calls up to 20 min, once per incident) and when it ends (calls resume, with its summary in the call).

D=/locks/autopilot
METHOD=$(echo "$hook_method" | tr '[:lower:]' '[:upper:]')
[ "$METHOD" = POST ] || exit 1
if [ -z "${WEBHOOK_TOKEN:-}" ] || [ "${x_token:-}" != "$WEBHOOK_TOKEN" ]; then echo "forbidden"; exit 1; fi
mkdir -p "$D" || exit 1
# webhookd passes the body only with Content-Type: application/json (or text/*); without it $1 is empty.
[ -n "$1" ] || { echo '{"ok":false,"error":"empty body: send Content-Type: application/json"}'; exit 1; }

now=$(date -u +%s)
echo "$1" | jq -c --argjson t "$now" '. + {received: $t}' > "$D/state.tmp" 2>/dev/null && mv "$D/state.tmp" "$D/state.json" || { echo '{"ok":false,"error":"bad body"}'; exit 1; }

# Forward run start/end to twilio-alert (in-cluster), once per run.
tw() { curl -sf -m 5 -X POST -H 'Content-Type: application/json' -d "$1" \
  "http://alerting-twilio.alerting:3000/autopilot?password=${ALERT_SERVICE_PASSWORD:-}" >/dev/null 2>&1; }
started=$(jq -r '.last_run.started // ""' "$D/state.json"); finished=$(jq -r '.last_run.finished // ""' "$D/state.json")
state=$(jq -r '.state // ""' "$D/state.json")
if [ "$state" = running ] && [ -n "$started" ] && [ "$started" != "$(cat "$D/fwd_started" 2>/dev/null)" ]; then
  tw "$(jq -c '{working: true, minutes: 20, summary: ("working on: " + ((.incident.alerts // []) | join(", ") | .[0:200]))}' "$D/state.json")" \
    && echo "$started" > "$D/fwd_started"
fi
if [ -n "$finished" ] && [ "$finished" != "$(cat "$D/fwd_finished" 2>/dev/null)" ]; then
  tw "$(jq -c '{working: false, result: (.last_run.result // ""), summary: ((.last_run.result // "") + ": " + (.last_run.summary // "") | .[0:300])}' "$D/state.json")" \
    && echo "$finished" > "$D/fwd_finished"
fi

# Hand over queued commands, then clear them.
if [ -s "$D/commands.json" ]; then cmds=$(cat "$D/commands.json"); : > "$D/commands.json"; else cmds='[]'; fi
jq -nc --argjson c "$cmds" '{ok: true, commands: $c}'
