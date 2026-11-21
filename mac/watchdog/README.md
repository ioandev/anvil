# ${ANVIL_NAME} watchdog (Mac mini)

Phones you if **${ANVIL_NAME} itself** is down, which the server's own alerting can't do. Runs on `${ANVIL_HOME_SSH}`
in `~/${ANVIL_NAME}-watchdog/` (this folder is the master copy: `docker-compose.yml`, `.env`, this README).

- Every minute: `GET https://status.${ANVIL_DOMAIN}/watchdog?code=…` (`WATCH_URL` in `.env`).
- Unreachable for 10 minutes → call ("the server has not answered for N minutes"), again every hour while it lasts.
- `{"ok": false}` (no Alertmanager heartbeat for 2 hours: the server's alerting is dead) → call with that reason.
- A silence on `Watchdog` in Alertmanager (https://${ANVIL_TAILNET_HOST}:8443, tailnet only) mutes it until
  the silence ends, even if ${ANVIL_NAME} then goes away (for maintenance).
- Look at it: `curl -s "http://127.0.0.1:3017/watchdog?password=$SERVICE_PASSWORD"` on the Mac.

## Ship a new image (from the Linux machine)

```sh
T=<tag>
podman build --platform linux/arm64 -t localhost/twilio-alert:$T /repos/twilio-webhook
podman save localhost/twilio-alert:$T | ssh ${ANVIL_HOME_SSH} \
  'PATH=$PATH:/Applications/Docker.app/Contents/Resources/bin; docker load && docker tag localhost/twilio-alert:'$T' twilio-alert:'$T
```

Also publish it in the registry as one multi-arch image (${ANVIL_NAME} runs the amd64 half), so it's not only on the Mac:

```sh
R=${ANVIL_REGISTRY}/twilio-alert
podman build -t $R:$T /repos/twilio-webhook
podman manifest create $R:$T-multi && podman manifest add $R:$T-multi containers-storage:$R:$T \
  && podman manifest add $R:$T-multi containers-storage:localhost/twilio-alert:$T && podman manifest push --all $R:$T-multi docker://$R:$T
```

Then set the tag in `docker-compose.yml`, copy it to `~/${ANVIL_NAME}-watchdog/` and run `docker compose up -d` there.
The Twilio credentials in `.env` are the same as the server's `platform/alerting/prod.env`.
