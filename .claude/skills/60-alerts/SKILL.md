---
name: 60-alerts
description: Seventh anvil bootstrap step. Places one test phone call (with the owner's consent), and installs the watchdog on the home machine that calls when the server itself disappears. Use after 50-demo-app.
---

# 60-alerts: being told when it breaks

1. **Ask the owner first**, then place one test call:
   `scripts/node.sh kubectl -n alerting exec deploy/alerting-prometheus -- wget -qO- --post-data '' "http://alerting-twilio:3000/test-call?password=$ALERT_SERVICE_PASSWORD"`
   (pass the password through stdin, never on a logged command line). The owner confirms the phone rang.
2. **Watchdog on the home machine**: write `~/$ANVIL_NAME-watchdog/.env` there (Twilio credentials, `ALERT_NUMBER`, the status
   code: generate it locally from anvil.env and `scp` it with mode 600; never commit it), then
   `scripts/home-deploy watchdog $ANVIL_REGISTRY/twilio-alert:$ANVIL_TWILIO_TAG`.
3. Check it reads the server: its log shows `/watchdog` → ok every minute.
4. Explain to the owner: answering pauses calls 60 min; voicemail doesn't count; quiet hours `$ANVIL_QUIET_HOURS`
   wait; a **silence** in Alertmanager (tailnet :8443) stops new calls and also mutes the home watchdog for that long.

Verify: Alertmanager shows `Watchdog` firing (that's the heartbeat: firing = healthy), `/watchdog?code=…` returns
`ok:true`.
