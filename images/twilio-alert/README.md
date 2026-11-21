# twilio-webhook (twilio-alert)

A small Node/TypeScript service around Twilio. It **phones you** when something is wrong, and can watch a server from
another machine.

- **`POST /alert?password=…`** (Alertmanager's webhook, with `send_resolved: true`): firing alerts become problems;
  resolved ones end them; an alert not re-sent for `ALERT_STALE_MINUTES` (20) is dropped. While any problem lasts,
  **the pager** calls `ALERT_NUMBER`, reading out the alert names: in a burst then less often (`CALL_SCHEDULE_MINUTES`,
  default `0,2,4,6,10,15,20,30,45,60`, then every `CALL_REPEAT_MINUTES`, 60), never in `QUIET_HOURS` (`03-09`,
  `Europe/London`; a call due then waits until they end and the schedule carries on from there), and not for
  `ACK_SNOOZE_MINUTES` (60) after you pick up (saying anything or nothing). Voicemail doesn't count
  (answering-machine detection), nor do unanswered, busy or failed calls: the schedule goes on.
- **`POST /test-call?password=…`**: one call now, outside the schedule, quiet hours and snooze.
- **`GET /pager?password=…`**: problems, calls so far, the next call, snooze, quiet hours, and the autopilot hold
  (`autopilotUntil`, ISO or null; `autopilotPending`; `autopilotSummary`).
- **`POST /autopilot?password=…`** (the autopilot, an automated fixer, says it's working; JSON body
  `{"working": true|false, "minutes": 20, "summary": "<short text>"}`):
  - `working:true`: calls are **held** until now + min(`minutes` (default 20), 20) minutes. **Once per incident**: if
    the current incident already had a hold, it's ignored (the answer says so). With no incident open, the hold waits
    for the next incident that opens before it runs out, and counts as that incident's one hold.
  - `working:false`: the hold ends now; `summary` (trimmed, at most 300 characters) is kept for the current incident,
    or for the next one if none is open (if it opens within 60 minutes).
  - Calls due during the hold are skipped (logged `Call held: autopilot working until …`). When the hold ends and
    problems remain, the next call comes then and the schedule carries on from there (no rush of missed calls).
  - Every call of an incident with a summary adds "Autopilot says: <summary>" to what's read out.
  - The hold never outlives the incident: all clear resets it, and a new incident gets a fresh allowance.
- **Watchdog** (when `WATCH_URL` is set): every minute it GETs `WATCH_URL`, which answers
  `{"ok": bool, "reason": "...", "mutedUntil": "<ISO>"|null}`. The URL unreachable for `WATCH_FAIL_MINUTES`
  (default 10), or answering `ok:false`, is a problem for the pager (same schedule, quiet hours and snooze). `mutedUntil` in the future silences it until then, remembered
  even if the server then goes away (so a silence set in Alertmanager mutes the watchdog too). It only pulls: the
  watched server never needs to reach it. `GET /watchdog?password=…` shows what it sees.
- **`GET /healthz`**: for probes (`{"ok": true, "twilioConfigured": …}`).
- **Twilio webhooks** (`/webhook/sms`, `/webhook/voice`, `/webhook/status`): SMS auto-replies, call forwarding to
  `FORWARD_TO_NUMBER`, delivery status logging; requests are checked against Twilio's signature (not in development).

Settings: see `.env.example` (Twilio: the Account SID plus an API key and secret, or the Auth Token). Shuts down cleanly on SIGTERM.

With the autopilot in front, give it time before the first call: on anvil, platform/alerting/app.yaml sets
`CALL_SCHEDULE_MINUTES=5,7,9,11,15,20,25,35,50,65` (a 5-minute grace; no code change).

## Where it runs (2026-10)

- **The server** (`platform/alerting`): Alertmanager's receiver; calls on alerts from Prometheus.
- **The home machine** (`mac/watchdog`): the watchdog, pulling `https://status.<domain>/watchdog?code=…`, so a fully
  dead server (or its alerting) still gets you a call.

## Develop and build

```sh
npm ci
npm run dev        # tsc, then node --env-file=.env dist/server.js
npm run build
podman build -t $ANVIL_REGISTRY/twilio-alert:<tag> .                    # amd64
podman build --platform linux/arm64 -t localhost/twilio-alert:<tag> .                     # arm64 (Mac)
```
