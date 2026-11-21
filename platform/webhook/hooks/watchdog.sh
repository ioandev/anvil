#!/bin/bash

# GET /watchdog?code=<STATUS_CODE> -> JSON for the Mac mini's watchdog (twilio-webhook WATCH_URL):
#   {"ok": true|false, "reason": "...", "mutedUntil": "<ISO>"|null}
# ok:false when Alertmanager's heartbeat (/am_heartbeat) is over 2 hours old: the server's alerting is not working,
# so it couldn't call about anything. mutedUntil: when "Watchdog" is silenced in Alertmanager, the end of that
# silence; the Mac stays quiet until then (even if ${PLATFORM_NAME:-anvil} then becomes unreachable).
# Always HTTP 200 with JSON, so the Mac can tell "server says not ok" from "server unreachable". Without the right
# code: a bare 500.

[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1

MAX_AGE=7200
AM=http://alerting-alertmanager.alerting:9093
now=$(date -u +%s)

# Silences covering the Watchdog alert: the latest end time among the active ones.
muted=$(curl -s -m 10 "$AM/api/v2/silences" 2>/dev/null | jq -r '
  [ .[]? | select(.status.state == "active")
    | select(any(.matchers[]; .name == "alertname" and (if .isRegex then ("Watchdog" | test("^(" + .value + ")$")) else .value == "Watchdog" end) and ((.isEqual // true) == true)))
    | .endsAt ] | max // empty' 2>/dev/null)

last=$(cat /locks/am_heartbeat 2>/dev/null)
if [ -z "$last" ]; then
  ok=false; reason="No heartbeat from Alertmanager yet"
else
  age=$(( now - last ))
  if [ "$age" -gt "$MAX_AGE" ]; then
    ok=false; reason="No heartbeat from Alertmanager for $(( age / 60 )) minutes"
  else
    ok=true; reason="Alertmanager heartbeat $(( age / 60 )) minutes ago"
  fi
fi

jq -cn --argjson ok "$ok" --arg r "$reason" --arg m "$muted" '{ok: $ok, reason: $r, mutedUntil: (if $m == "" then null else $m end)}'
