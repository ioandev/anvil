# autopilot on the Mac mini

Runs the autopilot (source and full docs: `/repos/autopilot/`, its README and `INTERFACES.md`) on
`${ANVIL_HOME_SSH}`. It watches the server's alerts over the tailnet and, when one stays on, runs Claude Code
headless to diagnose and fix it with live-only actions (rollout restart/undo, re-run a CronJob, delete one stuck
pod, prune images, restart `` / `${ANVIL_NAME}-watchdog` / `openbao` here), then reports.

On the Mac, `~/${ANVIL_NAME}-autopilot/` holds only `docker-compose.yml` (this folder's) and `autopilot.yaml` (a copy of the repo's
`autopilot.yaml`, used when the clone fails). No source code, no secrets: those come from OpenBao
with `~/${ANVIL_NAME}-openbao/claude.approle`.

## What it needs

| Thing | Where |
|---|---|
| Claude subscription token | OpenBao `secret/ops/autopilot` `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`; renew before it expires) |
| Read-only deploy key for the repo (clone only, for context) | OpenBao `secret/ops/autopilot` `GITHUB_DEPLOY_KEY` (without it, runs work without the repo) |
| Heartbeat token | `WEBHOOK_TOKEN_REFS` (compose): `ops/autopilot#WEBHOOK_TOKEN`, else `ops/platform#WEBHOOK_TOKEN` |
| Status code, SSH key, age key, off-site + email keys | the OpenBao refs in `autopilot.yaml` `secrets:` |
| AppRole | `~/${ANVIL_NAME}-openbao/claude.approle` (mounted read-only) |

## Ship a new image (from the Linux machine)

```sh
cd the autopilot repo && ./build.sh <n>          # pushes ${ANVIL_REGISTRY}/autopilot:<sha>-<n>
R=${ANVIL_REGISTRY}/autopilot; T=<sha>-<n>
podman save $R:$T-arm64 | ssh ${ANVIL_HOME_SSH} \
  'PATH=$PATH:/Applications/Docker.app/Contents/Resources/bin; docker load && docker tag '$R:$T-arm64' '$R:$T
```

Then set the tag in `docker-compose.yml`, copy it and `autopilot.yaml` to `~/${ANVIL_NAME}-autopilot/`, and on the Mac:

```sh
mkdir -p ~/${ANVIL_NAME}-autopilot/state ~/${ANVIL_NAME}-autopilot-runs && chmod 700 ~/${ANVIL_NAME}-autopilot-runs
cd ~/${ANVIL_NAME}-autopilot && docker compose up -d && docker compose logs -f autopilot
```

## Checks after starting

- Log says `autopilot <tag> watching; state idle` and no `poll failed` lines (if it can't resolve the tailnet names,
  uncomment `extra_hosts` in the compose file).
- `docker exec autopilot /opt/autopilot/bin/watch --once` prints `"poll_ok": true`.
- `docker exec autopilot docker ps` lists the containers (else the socket isn't usable by uid 5500: check
  `docker exec autopilot ls -ln /var/run/docker.sock` and adjust `group_add`; until then the `mac-services` skill
  reports that it can't reach Docker).
- `https://status.${ANVIL_DOMAIN}/autopilot?code=…` shows a fresh heartbeat (no `heartbeat:` complaints in the log).

## Operating it

- Pause (10–120 min) / resume / reset: the links on `https://status.${ANVIL_DOMAIN}/autopilot?code=…`. Calls aren't paused.
- Records: `~/${ANVIL_NAME}-autopilot-runs/<UTC timestamp>/` (`transcript.jsonl` is everything, including anything secret Claude
  saw, and so is `transcript.md`, its readable form: keep the folder private; `transcript.redacted.md` is scrubbed), and
  `s3://${ANVIL_OPENBAO_BUCKET}/autopilot/<ts>/transcript.jsonl.age` (decrypt with the SOPS age key).
- Stop: `cd ~/${ANVIL_NAME}-autopilot && docker compose down` (a running run is killed and reported as interrupted next start).
