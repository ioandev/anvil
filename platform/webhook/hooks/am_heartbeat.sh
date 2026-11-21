#!/bin/bash

# POST /am_heartbeat?token=<WEBHOOK_TOKEN>: Alertmanager's heartbeat (its always-firing "Watchdog" alert, every
# 15 minutes; see platform/alerting). Records the time; /watchdog reports it to the Mac's watchdog.
# (Token in the query: Alertmanager's webhook can't send a custom X-Token header.)

if [ -z "${WEBHOOK_TOKEN:-}" ] || [ "${token:-}" != "$WEBHOOK_TOKEN" ]; then
  echo "forbidden"
  exit 1
fi
date -u +%s > /locks/am_heartbeat.tmp && mv /locks/am_heartbeat.tmp /locks/am_heartbeat || exit 1
echo "ok"
