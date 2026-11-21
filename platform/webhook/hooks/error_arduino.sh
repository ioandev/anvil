#!/bin/bash

# Script for webhookd that latches an error state (polled by the arduino and by the owner).
# POST /error_arduino  (header X-Token: $WEBHOOK_TOKEN) -> appends {"error": "..."} to the lock, returns 200;
#                      without the right token nothing is stored and it returns 500
# GET  /error_arduino?code=<STATUS_CODE> -> 500 + the logged errors while the lock is set, 200 "ok" otherwise.
#                      Without the right code: a bare 500, whatever the state.
# The lock is cleared from the repo with platform/webhook/clear-error-arduino.sh
# Posters inside the cluster use http://webhook.webhook:9000/error_arduino (health-watch, server-backup).

LOCK_FILE=/locks/error_arduino.lock

METHOD=$(echo "$hook_method" | tr '[:lower:]' '[:upper:]')
PAYLOAD="$1"

# webhookd passes request headers as lowercased env vars (X-Token -> x_token)
authorized() {
  [ -n "${WEBHOOK_TOKEN:-}" ] && [ "${x_token:-}" = "$WEBHOOK_TOKEN" ]
}

case "$METHOD" in
  POST)
    if ! authorized; then
      echo "forbidden"
      exit 1
    fi
    ERROR=$(echo "$PAYLOAD" | jq -r '.error // empty' 2>/dev/null)

    # Fall back to the raw body if it is not JSON or carries no error field
    if [ -z "$ERROR" ]; then
      ERROR="$PAYLOAD"
    fi

    if [ -z "$ERROR" ]; then
      ERROR="(empty error)"
    fi

    # One short line per error so GET stays readable
    ERROR=$(echo "$ERROR" | tr '\n' ' ' | cut -c1-300)

    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $ERROR" >> "$LOCK_FILE" || exit 1
    exit 0
    ;;
  GET)
    # Only callers with ?code=<STATUS_CODE> learn anything: everyone else gets a bare 500.
    [ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1
    if [ -f "$LOCK_FILE" ]; then
      cat "$LOCK_FILE"
      exit 1
    fi
    echo "ok"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
