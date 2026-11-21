#!/bin/bash

# GET  /backups ?code=<STATUS_CODE> -> 200 while the last report says OK and is under 45 minutes old, else 500 (also when the reporter,
#                webhook/health-watch, has stopped: silence must not look like health). The body is one short line.
# POST /backups (header X-Token) with {"ok": true|false, "detail": "..."}: health-watch's report, every 15 minutes.

STATE=/locks/status_backups.json
MAX_AGE=2700

METHOD=$(echo "$hook_method" | tr '[:lower:]' '[:upper:]')

case "$METHOD" in
  POST)
    if [ -z "${WEBHOOK_TOKEN:-}" ] || [ "${x_token:-}" != "$WEBHOOK_TOKEN" ]; then
      echo "forbidden"
      exit 1
    fi
    echo "$1" | jq -c --arg t "$(date -u +%s)" '{ok: (.ok == true), detail: ((.detail // "") | tostring | .[0:200]), at: ($t | tonumber)}' \
      > "$STATE.tmp" && mv "$STATE.tmp" "$STATE" || exit 1
    exit 0
    ;;
  GET)
    # Only callers with ?code=<STATUS_CODE> learn anything: everyone else gets a bare 500.
    [ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1
    if [ ! -f "$STATE" ]; then
      echo "no report yet"
      exit 1
    fi
    age=$(( $(date -u +%s) - $(jq -r .at "$STATE") ))
    if [ "$age" -gt "$MAX_AGE" ]; then
      echo "stale: no report for $(( age / 60 )) minutes (health-watch not running?)"
      exit 1
    fi
    if [ "$(jq -r .ok "$STATE")" = true ]; then
      echo "ok: $(jq -r .detail "$STATE")"
      exit 0
    fi
    echo "$(jq -r .detail "$STATE")"
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
