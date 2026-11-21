#!/bin/bash

# GET|HEAD /up  (no code) -> 200 or 500 and nothing else: for outside uptime monitors (e.g. UptimeRobot), which must not
# know the status code. 200 only if the last /overall verdict (the probe runs it every 30 s) was green and is under
# 5 minutes old; 500 otherwise (red, stale, or never checked). It runs no checks itself, so calling it is cheap and
# reveals nothing but up/down. Details stay behind ?code= on /overall.
STATE=/locks/status_up.json
[ -f "$STATE" ] || exit 1
at=$(jq -r '.at // 0' "$STATE" 2>/dev/null) || exit 1
[ $(( $(date -u +%s) - ${at:-0} )) -le 300 ] || exit 1
[ "$(jq -r '.ok' "$STATE" 2>/dev/null)" = true ]
