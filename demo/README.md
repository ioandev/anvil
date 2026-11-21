# anvil-demo

A tiny guestbook that runs on anvil to show the platform working, live: **break it on stage → an alert fires → the
autopilot fixes it.** Web page + JSON API + a background worker + MariaDB + Prometheus metrics, in one small image.

- **Web** (`dist/server.js`, UID 6000, 2 replicas): the page lists the latest entries with a form; new entries start
  *pending*.
- **Worker** (`dist/worker.js`, UID 6001, singleton): every 5 s it takes the queue, marks entries *approved* and counts
  them per day. Its heartbeat metric is what a "stuck worker" alert watches.
- **Break switch**: `POST /admin/break` puts the app into a failure mode, held **in memory only**, so a restart (the
  autopilot's main move) always fixes it.

TypeScript on Node.js 24 (the LTS line on 2026-10-27; Node 26 becomes LTS on 2026-10-28: bump the two `FROM` lines,
`engines` and `@types/node` then). Dependencies: `fastify`, `mysql2`, `prom-client`. No frontend build.

Manifest: [`../apps/anvil-demo/app.yaml`](../apps/anvil-demo/app.yaml).

## Run it

```sh
npm ci
npm run build
npm test                      # type-checks src + tests, then node:test (no database needed)

# Locally without a database (in-memory store, single process: the worker won't see the web's entries):
DEMO_MEMORY_STORE=1 ADMIN_TOKEN=dev-only-token npm start          # http://localhost:8080, metrics on :9090

# Image (one image, two commands):
podman build --platform linux/amd64 -t anvil-demo:dev .
podman run --rm -p 8080:8080 --read-only --tmpfs /tmp --user 6000:6000 -e DB_HOST=… -e DB_NAME=… -e DB_USER=… -e DB_PASSWORD=… anvil-demo:dev
podman run --rm --read-only --tmpfs /tmp --user 6001:6001 -e DB_HOST=… … anvil-demo:dev dist/worker.js
```

The image is distroless (no shell, no package manager), runs as any numeric non-root UID, writes nothing to disk
(read-only root filesystem is fine; `/tmp` is mounted only as a precaution), and holds no secrets.

## Endpoints

Web, port `PORT` (8080, behind the Ingress):

| Method | Path | What |
|---|---|---|
| GET | `/` | the guestbook page (latest 20 entries, totals, form) |
| GET | `/api/entries?limit=20` | latest entries as JSON (`limit` 1–100) |
| POST | `/api/entries` | new entry: JSON `{"name","message"}` → 201, or the HTML form (urlencoded) → 303 to `/` |
| GET | `/healthz` | process alive (never touches the database): **liveness** |
| GET | `/readyz` | database reachable and schema ready: **readiness** |
| POST | `/admin/break` | `{"mode": "hang" \| "slow" \| "errors" \| "crash" \| "stuck"}`, header `X-Admin-Token` |
| POST | `/admin/fix` | clears every mode, on every web pod and the worker |

Web metrics, port `METRICS_PORT` (9090, cluster-internal Service port only, not on the Ingress): `GET /metrics`.

Worker, port `WORKER_PORT` (8081, cluster-internal only): `GET /healthz`, `GET /readyz`, `GET /metrics`,
`POST /admin/break` (`{"mode":"stuck"}`), `POST /admin/fix`.

Rules: name 1–40 characters (one line), message 1–280 characters; control and bidi-override characters are refused;
everything is HTML-escaped on output and the page sends a strict Content-Security-Policy. `POST /api/entries` is rate
limited per client IP (`RATE_LIMIT_MAX` per `RATE_LIMIT_WINDOW_SECONDS`, default 5 per 60 s, per pod) → 429 with
`Retry-After`. The client IP is `CF-Connecting-IP` (the platform only accepts traffic from Cloudflare), else the socket
address; `X-Forwarded-For` is ignored. `/admin/*` is limited to 30 requests a minute per IP.

### Metrics

| Metric | Type | Meaning |
|---|---|---|
| `anvil_demo_http_requests_total{method,route,status_code}` | counter | requests |
| `anvil_demo_http_request_duration_seconds{method,route}` | histogram | latency |
| `anvil_demo_entries_created_total` | counter | entries created (per pod) |
| `anvil_demo_db_errors_total{op}` | counter | failed database calls (`ping`, `page`, `list`, `insert`) |
| `anvil_demo_rate_limited_total` | counter | 429s |
| `anvil_demo_break_mode{mode}` | gauge | 1 for the active break mode |
| `anvil_demo_worker_last_run_timestamp_seconds` | gauge | **heartbeat**: last successful queue run |
| `anvil_demo_worker_processed_total` / `_queue_depth` / `_errors_total` / `_stuck` | | worker |

Plus Node's default process metrics. Every series carries `app="anvil-demo"` and `component="web"|"worker"`.

## Environment

| Variable | Default | |
|---|---|---|
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | port 3306 | from the platform's `atlas-db` Secret; required |
| `ADMIN_TOKEN` | unset | from the `anvil-demo` Secret; **unset = `/admin/*` answers 404** |
| `PORT` / `METRICS_PORT` / `WORKER_PORT` | 8080 / 9090 / 8081 | |
| `RATE_LIMIT_MAX`, `RATE_LIMIT_WINDOW_SECONDS` | 5, 60 | |
| `SLOW_MS` | 8000 | delay per response in `slow` mode |
| `PEERS_HOST` | unset | headless Service name: a break/fix is passed on to every other web pod |
| `POD_IP` | unset | (downward API) so a pod doesn't forward to itself |
| `WORKER_ADMIN_URL` | unset | lets the web's `/admin/break {"mode":"stuck"}` and `/admin/fix` reach the worker |
| `WORKER_INTERVAL_SECONDS` | 5 | |
| `BREAK_ON_START` | unset | `1` = the server exits with status 1 at start (the "bad release") |
| `SHUTDOWN_TIMEOUT_SECONDS` | 10 | hard limit for the graceful shutdown |
| `LOG_LEVEL` | info | JSON logs on stdout |
| `DEMO_MEMORY_STORE` | unset | `1` = no database (local playing only) |

**Database:** the schema is created at start with `CREATE TABLE IF NOT EXISTS` under a MariaDB `GET_LOCK`, so two
copies starting together (a rolling deploy) are safe, and the process starts even while the database is down
(`/healthz` 200, `/readyz` 503 until it's reachable). Tables: `entries`, `entry_queue`, `daily_stats`. Future schema
changes must be additive: the previous release keeps running during a rolling deploy. The platform's nightly
off-site backup of the shared MariaDB covers this database; there is no separate backup job (UID 6002 stays reserved
for one).

**Shutdown:** on SIGTERM the server stops accepting connections, finishes in-flight requests (cutting short any
artificial `slow`/`hang` delay), closes the pool and exits 0, or exits 1 after 10 s at the latest. The pod's `preStop`
sleeps 5 s first so Traefik stops sending traffic before that.

## Break modes

`/admin/break` on the public URL breaks **every web pod** (it fans out through the headless Service
`anvil-demo-web-peers`); add `"all": false` to break only the pod that answers. The admin routes keep answering in
every mode, so a pod you can reach can always be fixed with `/admin/fix`.

| Mode | What happens | What heals it |
|---|---|---|
| `hang` | every request (incl. `/healthz`) stalls forever | **Kubernetes alone**: liveness fails 5× → restart in ~2.5 min |
| `slow` | every response takes 8 s: readiness (2 s timeout) fails, liveness (10 s) passes | the **autopilot** (restart) |
| `errors` | everything but `/healthz` returns 500, readiness fails | the **autopilot** (restart) |
| `crash` | the process exits with status 1 once | **Kubernetes alone**: container restarts at once |
| `stuck` (worker) | worker stops processing; `/healthz` stays 200, heartbeat goes stale | the **autopilot** (restart the worker) |
| `BREAK_ON_START=1` | new release crash-loops; old pods keep serving | the **autopilot** (`kubectl rollout undo`) |

## How anvil watches it

`sites.yaml` (`anvil-demo`) gives the blackbox probes (`https://demo.<domain>/` and `/readyz`, through Cloudflare) and
the scrape targets; `platform/alerting/app.yaml` has the rules. The ones the demo trips:

| Alert | Fires when | After |
|---|---|---|
| `SiteDown` | a probe of `demo.<domain>` fails | 5 min (suppressed for 10 min after a Deployment changes) |
| `ServiceUnavailable` | fewer ready web/worker pods than wanted | 5 min (same suppression) |
| `AnvilDemoWorkerStuck` | heartbeat older than 120 s | 2 min more, so ~4 min after the worker stops |
| `PodCannotStart` | a pod in CrashLoopBackOff etc. | 5 min, counted only once the pod is 10 min old: ~15 min |
| `PodRestartingOften` | > 3 restarts in 30 min | at once, for pods older than 10 min |

Scrape targets must match the manifest's Service ports: web metrics are on **`anvil-demo-web.anvil-demo:9090`** (kept
off the public port on purpose) and the worker's on **`anvil-demo-worker.anvil-demo:8081`**, both `/metrics`.

For a shorter stage show, a demo-only rule can fire sooner than `SiteDown`, e.g.:

```yaml
- alert: AnvilDemoDown
  expr: max by (instance) (probe_success{job="sites", instance=~"https://demo\\..*"}) == 0
  for: 1m
  labels: { severity: critical }
  annotations: { summary: "{{ $labels.instance }} is down (anvil-demo)" }
```

## The live-demo script

Setup (once, before the talk): the app is deployed, `https://demo.<domain>` shows the guestbook, the alerting has the
probes/scrapes/rules above, the autopilot is running, and nobody has broken anything in the last 30 minutes (restart
counts reset in `PodRestartingOften`'s window). On the presenter's laptop:

```sh
export DEMO=https://demo.example.com                       # your domain
export TOKEN="$(grep '^ADMIN_TOKEN=' apps/anvil-demo/prod.env | cut -d= -f2-)"   # never paste it on screen
brk() { curl -s -X POST "$DEMO/admin/break" -H "X-Admin-Token: $TOKEN" -H 'content-type: application/json' -d "{\"mode\":\"$1\"}"; echo; }
fix() { curl -s -X POST "$DEMO/admin/fix" -H "X-Admin-Token: $TOKEN" -H 'content-type: application/json' -d '{}'; echo; }
k() { scripts/node.sh kubectl -n anvil-demo "$@"; }        # or plain kubectl with your kubeconfig
```

Keep two panes open: `k get pods -w` and the guestbook in a browser. Times below are anvil's default rules (in
brackets: with the optional `AnvilDemoDown`). The phone call follows the alert after the platform's grace period.

**0. Show it working (1 min).** Sign the guestbook in the browser: the entry appears *pending*, a few seconds later
*approved* (the worker). Point at the `x-served-by` header / footer pod name changing between reloads (2 replicas).

**1. Kubernetes heals itself: `crash` (1 min).**
`brk crash` → both web pods exit; `k get pods` shows RESTARTS 1 and they're back within seconds. No alert, no call:
one crash isn't an incident (four within 30 min would be: `PodRestartingOften`).

**2. Kubernetes heals itself, slowly: `hang` (3 min).**
`brk hang` → the site stops answering at once (readiness fails in ~10 s, Traefik returns 503). The liveness probe
fails every 30 s; after 5 failures (~2.5 min) the kubelet restarts the containers (RESTARTS +1) and the site is back
without anyone touching it, before `SiteDown` (5 min) fires: no call. (With `AnvilDemoDown` the autopilot may get
there first with a restart; either way it ends fixed.) Talking point: liveness is deliberately slow so slow starts
aren't killed.

**3. The autopilot: `errors` (~6 min [~2 min]).**
`brk errors` → the API and page return 500, readiness fails, pods go 0/1 READY, the site shows 503.
After 5 min `SiteDown` and `ServiceUnavailable` fire [1 min: `AnvilDemoDown`] (Prometheus → Alertmanager → the
autopilot, and the phone). The autopilot reads the alert, sees the pods are unready while the process is alive, and runs its allowed
move: **restart `deploy/anvil-demo-web`** (a rolling restart). New pods start without the in-memory break → ready →
alert resolves → the call stops. (`slow` plays out the same way, just with 8-second responses instead of 500s.)

**4. The autopilot: a stuck worker (~5 min).**
`brk stuck` (goes through the web to the worker). Sign the guestbook: the entry stays *pending* and "waiting for the
worker" grows; `k get pods` shows everything healthy, because the worker is alive, just not working. After ~4 min
`AnvilDemoWorkerStuck` fires → the autopilot **restarts `deploy/anvil-demo-worker`** → the pending entries are approved
within seconds.

**5. The autopilot: a bad release (~10 min: start it before step 1 and come back to it at the end).**
```sh
k set env deploy/anvil-demo-web BREAK_ON_START=1      # "ship" a broken release (new ReplicaSet revision)
k rollout status deploy/anvil-demo-web               # hangs: the new pod is in CrashLoopBackOff
```
The site **stays up**: `maxUnavailable: 0` means the old pods keep serving until a new one is ready, which never
happens. Once the crash-looping pod is 10 min old `PodRestartingOften` fires (`PodCannotStart` 5 min later) → the autopilot sees a crash-looping pod from the newest revision and runs
**`kubectl rollout undo deploy/anvil-demo-web`** → the bad ReplicaSet scales to 0, the alert resolves. (A platform
`node.sh deploy anvil-demo` would also undo it, since the manifest has no `BREAK_ON_START`.)

### Fixing by hand (if the autopilot is off or slow)

| Situation | Command |
|---|---|
| any web mode, site still reachable (only some pods broken, `"all": false`) | `fix` |
| web pods unready (`errors`, `slow`, `hang`): the public URL can't reach them | `k rollout restart deploy/anvil-demo-web`, or `k port-forward deploy/anvil-demo-web 8080:8080` and POST `http://localhost:8080/admin/fix` with the token (fans out to every pod) |
| worker stuck | `fix` (passes it to the worker), or `k rollout restart deploy/anvil-demo-worker` |
| bad release | `k rollout undo deploy/anvil-demo-web` |
| a phone call already running | end it as the platform docs say (resolved alert to twilio-alert) |

After the talk: `fix`, check `k get pods` (all READY), and that the alerts have resolved.
