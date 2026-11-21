#!/bin/bash

# POST /autopilot_run (header X-Token, Content-Type: application/json): the autopilot uploads a run's scrubbed
# transcript, in parts (webhookd passes the body as one argv string, capped at 128 KiB):
#   {"id": "<run id = UTC time>", "part": 0, "parts": N, "text": "<markdown>", "meta": {...} (last part only)}
# Stored as /locks/autopilot/runs/<id>.md (+ <id>.json with the meta). Kept 90 days. Read with GET /autopilot_runs.

D=/locks/autopilot/runs
METHOD=$(echo "$hook_method" | tr '[:lower:]' '[:upper:]')
[ "$METHOD" = POST ] || exit 1
if [ -z "${WEBHOOK_TOKEN:-}" ] || [ "${x_token:-}" != "$WEBHOOK_TOKEN" ]; then echo "forbidden"; exit 1; fi
[ -n "$1" ] || { echo '{"ok":false,"error":"empty body: send Content-Type: application/json"}'; exit 1; }
mkdir -p "$D" || exit 1

id=$(echo "$1" | jq -r '.id // ""'); part=$(echo "$1" | jq -r '.part // 0'); parts=$(echo "$1" | jq -r '.parts // 1')
case "$id" in ''|*[!0-9A-Za-z_:.-]*) echo '{"ok":false,"error":"bad id"}'; exit 1 ;; esac
case "$part$parts" in *[!0-9]*) echo '{"ok":false,"error":"bad part"}'; exit 1 ;; esac
[ "$part" -lt 200 ] || { echo '{"ok":false,"error":"too many parts"}'; exit 1; }

f="$D/$id.md"
[ "$part" -eq 0 ] && : > "$f.part"
echo "$1" | jq -j '.text // ""' >> "$f.part" || exit 1
if [ "$part" -eq $((parts - 1)) ]; then
  mv "$f.part" "$f"
  echo "$1" | jq -c '.meta // {}' > "$D/$id.json"
  find "$D" -type f -mtime +90 -delete 2>/dev/null
fi
echo "{\"ok\":true,\"part\":$part,\"parts\":$parts}"
