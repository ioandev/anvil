# CLAUDE.md

**anvil**: one cloud server (Scaleway, Flatcar Linux + single-node k3s) behind Cloudflare that runs many small projects
safely: a shared MariaDB with least-privilege users, encrypted secrets in git, nightly off-site backups the server
can't delete, phone calls when something breaks, a watchdog on a home machine, and an autopilot (Claude Code) that
fixes what it safely can. Everything is reproducible from this repo plus `anvil.env`.

Layout: `infra/` (Terraform + Butane + node manifests + state), `platform/<ns>/` (the shared stack), `apps/<ns>/`
(projects), `sites.yaml` (every site's facts), `scripts/`, `images/` (images we build), `mac/` (home machine),
`docs/` (the docs website), `.claude/skills/` (bootstrap steps 00-99 and operations). Settings and secrets:
`anvil.env` (gitignored; encrypted twin `anvil.env.sops`). Open tasks only a person can do: `HUMAN.md`.

**Bootstrapping a new platform:** run the skills in `.claude/skills/` in order (`00-preflight` … `80-verify`;
`99-teardown` removes everything). Each one checks its own result and is safe to re-run.

**Terraform:** never `terraform destroy` / `make destroy`, and never apply a plan that destroys or replaces
`scaleway_instance_server.k3s` or `scaleway_instance_ip.public`, without asking the owner first (except in
`99-teardown`, which the owner starts). Always `make plan` and read it before `make apply`.

**Never create, resize or add a bigger or more expensive server without the owner's confirmation first**: no larger
instance type, no new pool or pool node, no extra or bigger load-test machine, even when a test is running and the next
step seems obvious. Ask first, saying the size, its hourly price **and whether it means a restart**, and wait for a yes.
**Resizing a server restarts it** (stop, migrate, start: about a minute, then every pod on it starts again), so a
resize of a server a site lives on is a planned outage. A local-SSD server (the DEV1 types) can't be resized at all
(a new server). **Hourly billing:** every started hour is billed in full and a resize starts a new one: plan pool work
in whole hours, keep one session for the day, delete test machines as soon as the last run ends.

## Rules for every app (existing and new)

**Before publishing a site, a launch, or any change to caching, health checks or server sizes: read `CAPACITY.md`** (what a ceiling test taught: port-check readiness, built-in preStop sleep, an edge-cache decision per site, probes that bypass the cache, bounded queues, capacity alerts, and never a bigger server without the owner's yes).

1. **One namespace per project.** `apps/<ns>/app.yaml` holds the Namespace plus everything in it; the project has an
   entry in `sites.yaml`. Start new ones with `scripts/new-site init` (it writes both).
2. **Service names (= in-cluster hostnames) are project-prefixed and unique across the cluster**: `shop-api`, never
   `api`. Call another namespace by its full name (`atlas-mariadb.atlas.svc`).
3. **Every container runs as its own numeric UID/GID**, from its namespace's block in `sites.yaml` (`uids:`; a new
   project takes `next_uid_block`). Set `runAsUser`/`runAsGroup` (plus `fsGroup` with a volume) explicitly even when
   the image has a USER. Never reuse a UID (`retired_uids`).
4. **One shared MariaDB, `atlas`**: each project gets its own database and exactly two users limited to it
   (`<ns>_rw` for the app, `<ns>_ro` read-only). Never give an app root or another project's user.
5. **`enableServiceLinks: false` on every pod** (otherwise Kubernetes injects `X_PORT=tcp://…` variables that clobber
   apps' own settings).
6. **Bots, cron jobs and queue workers are singletons**: `strategy: Recreate`, one replica.
7. **Client IP:** behind Cloudflare → ServiceLB → Traefik; use `CF-Connecting-IP`. Never the left-most
   `X-Forwarded-For` entry (client-forgeable) or `X-Real-Ip` (internal).
8. **Secrets** never go in `app.yaml` or any tracked plaintext file. App secrets: `apps/<ns>/prod.env` (gitignored,
   encrypted twin `prod.env.sops`) → Secret `<ns>`; `make-secrets.py` builds it.
9. **Ingress:** `ingressClassName: traefik`, entrypoint `websecure`, `tls.hosts`, **no `certresolver`** (TLS comes from
   Cloudflare Origin CA certs in Traefik's default TLSStore). A new domain needs its Cloudflare zone active **and its
   edge certificate issued** before the DNS cutover.
10. **www:** a site's apex in its `www:` list gets `www.<apex>` → `https://<apex>/<path>` (301), one shared route.
11. **Everything restarts, forever.** Deployments/StatefulSets only; every HTTP service has a readinessProbe and a
    livenessProbe on an endpoint that really answers (`initialDelaySeconds: 120, periodSeconds: 30,
    timeoutSeconds: 10, failureThreshold: 5`). k3s restarts forever (systemd drop-in in Butane).
12. **Throwaway things start with `zz-`** (namespace, Deployment, Job…), live in their own `zz-…` namespace and are
    deleted the same session. Alerts still see them: delete within 10 minutes.
13. **Every app is watched before it counts as deployed**: a probe URL in `sites.yaml` (`probes:`) for each part that
    can fail on its own; then `make-secrets.py` and `node.sh deploy alerting`. Check `/cluster` is 200.
14. **Every Secret an app references exists before it's deployed** (else `CreateContainerConfigError` forever).
15. **Probes must hit an endpoint that answers on that port** (curl it from inside the cluster first).
16. **Config changes never need a manual restart**: `node.sh deploy` fingerprints each workload's Secrets/ConfigMaps
    (annotation `anvil/config-hash`) and restarts only the ones whose config changed.
17. **Standard labels on every object**: `app.kubernetes.io/part-of: <ns>`, `app.kubernetes.io/managed-by: anvil`,
    `anvil/tier: platform|app`; on workloads also `app.kubernetes.io/name` and `app.kubernetes.io/component`
    (`web`, `server`, `bot`, `job`, `backup`, `database`, `monitoring`, `app`), the last two also on the pod
    template. Backup CronJobs **must** have `component: backup`: that's how the backup checks find them.
18. **Templates are valid YAML before rendering**: quote any flow-style value with `${ANVIL_*}` in it
    (`hosts: ["demo.${ANVIL_DOMAIN}"]`). Unknown `${ANVIL_*}` fails the deploy.
19. **Every public site gets an edge-cache decision**: `edge_cache:` on its namespace in `sites.yaml`, either a cache time
    for anonymous visitors (the default answer: pages the same for everyone are served by Cloudflare, so a crowd costs
    the server nothing) or `false` with the reason (private, an API, live data). Exclude live paths (websockets, event
    streams) and admin pages; allow only public read-only API paths. Then `scripts/cloudflare-cache-rules.py`,
    `scripts/sites.py render` and `node.sh deploy edge-warmer`, and check `MISS` → `HIT` anonymous, `DYNAMIC` with a
    cookie. Never cache a page that is personal without a cookie. Build files and resized images (`/_next/static/`,
    `/_next/image`, `/_astro/`) are cached a day for everyone. Deploys purge the zone; probes send a cookie, so they
    always measure the site itself. `scripts/edge-cache-monitor` samples HIT/MISS over hours.

`python3 -I scripts/sites.py check` enforces rules 2, 3, 5, 11, 13, 17 (partly), 19 and the hosts; the pre-commit hook
runs it.

## Sites and UIDs/GIDs

**`sites.yaml` is the source**; this table is generated (`python3 -I scripts/sites.py render`).

<!-- BEGIN generated from sites.yaml by scripts/sites.py render: edit sites.yaml, not this -->
| Namespace | Public hosts | Workload (container) → UID:GID |
|---|---|---|
| anvil-demo | demo.${ANVIL_DOMAIN} (the demo app: guestbook + worker, with a break switch for live demos) | anvil-demo-web 6000 · anvil-demo-worker 6001 · 6005: anvil-demo-mariadb: its own database server when moved (scripts/move-db) · 6006: anvil-demo-web-maintenance: the 503 responder during a cutover · 6007: anvil-demo-mariadb-backup: its nightly off-site backup while moved |
| anvil-demo-loadtest | (the demo's load-test copy (scripts/loadtest anvil-demo): exists only during a test, on the demo pool, behind a password; its host has no probe on purpose (usually absent)) | 6010: its MariaDB (generated data only) · 6011: web · 6012: worker |
| webhook | status.${ANVIL_DOMAIN} (webhookd: status endpoints, error latch, autopilot links) | webhook 5050 · health-watch 5051 · webhook-files 5052 · autopilot-viewer 5053 |
| alerting | (internal; tailnet: Alertmanager :8443, Prometheus :9443, Grafana :3443) | alerting-twilio 5490 · alerting-blackbox 5491 · alerting-prometheus 5492 · alerting-alertmanager 5493 · alerting-grafana 5494 · alerting-kube-state-metrics 5495 · alerting-mysqld-exporter 5496 · alerting-node-exporter 5497 · 5490: also the home machine's watchdog container |
| atlas | (internal: atlas-mariadb.atlas:3306, the shared MariaDB) | atlas-mariadb 5450 · atlas-backup 5480 · backup-watch 5483 |
| autopilot-access | (the autopilot's narrow cluster login (ServiceAccount, RBAC, an admission policy; no pods)) |  |
| edge-warmer | (keeps Cloudflare's cache of every edge_cache site warm, and purges a site when its content changes) | edge-warmer 5540 · edge-purger 5541 |
| dozzle | (Tailscale only (no DNS, Service or Ingress)) | dozzle 5410 |
| origin-ca | (Origin CA certs → Traefik's default TLSStore (no pods)) |  |
| www | (www.<domain> → apex (one IngressRoute, no pods; built from each site's `www:`)) |  |
<!-- END generated -->

## Secrets (SOPS + age)

- Plaintext working copies are gitignored; encrypted twins `<file>.sops` are committed. List: `scripts/secrets.sh`
  (`anvil.env`, `apps/*/prod.env`, `infra/terraform.tfstate`, the keys in `.data/`).
- **The age private key is the only way to decrypt them**: `~/.config/sops/age/keys.txt` plus your password manager.
  Lose both and every secret in git is gone.
- After editing any secret: `make secrets-encrypt` (the pre-commit hook also does it and refuses stale twins).
- A vault on the home machine (OpenBao, optional) holds **only operator/troubleshooting credentials** for the
  autopilot (cluster access, the status code, the webhook token, backup keys), **never the apps' secrets**.

## Monitoring

- **Alert levels:** `critical` phones; **`notify` writes one line a day per alert and site to the error latch**
  (webhookd `am_latch`): CPU over 65% counting steal for 15 min, a site's failed requests (5xx/429/408, not
  404/401/403) over 5%, memory under 600 MB, memory pressure, swap, disk, slow sites and probes, OOM kills; over 20% of
  a site's requests failing phones (`SiteErrorsCritical`); `warning` goes nowhere. Node figures from
  `alerting-node-exporter` (one unprivileged pod per node, no host access), site figures from Traefik's own metrics
  (every Traefik pod in kube-system, a pool's direct-mode one included). `/memory` (public, no code) is 200 while the node has 500 MB available;
  keep about 1 GB free.

- Prometheus probes every `probes:` URL through Cloudflare every 30 s; kube-state-metrics covers every workload.
  Alertmanager → twilio-alert phones the owner (rules wait 5 min, then the first call 2 min later, then a back-off;
  quiet hours wait); resolved alerts never call. **If the autopilot gives up, twilio-alert calls at once**, even when
  the autopilot's own restart or rollback made the alert look resolved (rules ignore workloads changed in the last 10 min). An always-firing `Watchdog` alert is the heartbeat the home machine's
  watchdog reads; if the server disappears, the home machine calls.
- **Stopping calls that already started:** a silence stops new notifications but not twilio-alert's schedule. POST a
  resolved alert to twilio-alert (see docs: Operations → Silence alerts), or answer the phone (pauses 60 min).
  **Before removing a silence**, check Alertmanager no longer holds the alert (`amtool alert query`).
- Status endpoints at `https://status.<domain>` (every GET needs `?code=<STATUS_CODE>`, else a bare 500; POSTs need
  `X-Token`): `/overall` (= `/space`, `/database`, `/backups`, `/cluster`), `/error_arduino` (an error latch, cleared
  by hand), `/autopilot`, `/os` (500 when a newer Flatcar release is out: OS updates are manual; not part of
  `/overall`, so it never phones), `/up` (no code: 200/500 only, for outside monitors). Rate-limited per visitor IP.

## Working on this platform (gotchas)

- **Deploy from a clean worktree of a commit**, never from a tree holding someone's unfinished changes.
- **Build and deploy so a failure stops everything** (`set -euo pipefail`).
- **Image tags:** `<YYYYMMDD>-<short sha>` (`scripts/image-tag`); `-dirty-<HHMMSS>` builds are for testing only.
  Never reuse or move a tag, no `:latest`.
- **Scaleway blocks outbound SMTP (25/465/587)**: send email through Scaleway TEM on 2587, or its HTTP API.
- **Create cloud API keys without an expiry date**: an expired key fails silently.
- After a nameserver switch, Google Public DNS can keep the old answers for up to 2 days: check
  `dns.google/resolve?name=<host>&type=A` and flush at https://developers.google.com/speed/public-dns/cache.
- **The permission checks may block some actions** (bulk deletes, DNS changes, using credentials): don't work around
  them; write the exact command into `HUMAN.md` for the owner.
