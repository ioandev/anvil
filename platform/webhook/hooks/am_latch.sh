#!/bin/bash

# POST /am_latch?token=<WEBHOOK_TOKEN>: Alertmanager's `notify` alerts (severity="notify": things to look at soon,
# not worth a phone call; platform/alerting) are written to the error latch (/error_arduino), one line per alert and
# site per day, so a problem that lasts doesn't fill the latch. (Token in the query: Alertmanager's webhook can't
# send a custom X-Token header.)

if [ -z "${WEBHOOK_TOKEN:-}" ] || [ "${token:-}" != "$WEBHOOK_TOKEN" ]; then
  echo "forbidden"
  exit 1
fi
LOCK_FILE=/locks/error_arduino.lock
today=$(date -u +%F)
echo "$1" | jq -r '.alerts[]? | select(.status == "firing")
  | "\(.labels.alertname)|\(.labels.instance // .labels.service // .labels.node // .labels.namespace // "")|\(.annotations.summary // "")"' 2>/dev/null |
while IFS='|' read -r name where summary; do
  key="alert $name $where $today"
  grep -qF -- "$key" "$LOCK_FILE" 2>/dev/null && continue
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $key: $(echo "$summary" | tr '\n' ' ' | cut -c1-220)" >> "$LOCK_FILE"
done
echo "ok"
