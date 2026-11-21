---
name: 80-verify
description: Ninth anvil bootstrap step. Checks the whole platform end to end (every status endpoint, every probe, backups, a restore test, the secrets in git) and writes a short report. Use after 70-autopilot, and any time to audit a running platform.
---

# 80-verify: everything green, proven

Changes nothing except a throwaway restore. Report a table: check · result · evidence.

1. `https://status.$ANVIL_DOMAIN/overall?code=…` → 200 and `?strict=1` → 200 (no work-in-progress exceptions).
2. `make check` (sites.yaml vs manifests; secrets' twins current; no plaintext tracked).
3. For every namespace: `scripts/node.sh diff <ns>` shows nothing (the cluster runs exactly the repo).
4. Firewall from outside: `curl -m 5 https://$ANVIL_SERVER_IP` fails; `nc -z -w 5 $ANVIL_SERVER_IP 22` fails; the
   SSH port answers.
5. Backups: today's object exists in the bucket (list with an **admin** key on this machine, not the server's);
   `/backups?code=…` → 200.
6. **Restore test**: download the newest `anvil_demo` dump, load it into a throwaway database
   (`zz_restore_test`) on atlas, count rows, drop it.
7. Alerts: Alertmanager has only `Watchdog`; `/pager?password=…` on twilio-alert shows `"problems":[]`.
8. Autopilot: IDLE, heartbeat fresh.
9. **Capacity and failure alerts are live**: Prometheus targets `node` (one per node) and `traefik` are up
   (`up{job=~"node|traefik"}`), `node_cpu_seconds_total` has a `steal` mode, `traefik_service_requests_total` has
   series; `https://status.$ANVIL_DOMAIN/memory` → 200. A `notify` alert writes to the error latch (if any fired).
10. **Edge cache**: as an anonymous visitor (`curl -sI -A "Mozilla/5.0" https://demo.$ANVIL_DOMAIN/?v=$RANDOM` twice):
    `cf-cache-status: MISS`, then `HIT`; with `-H 'Cookie: x=1'` → `DYNAMIC`; `/healthz`, `/readyz` and `/admin` →
    `DYNAMIC`. The warmer's log (`kubectl -n edge-warmer logs deploy/edge-warmer`) counts requests; the purger's says
    whether it has its token.
11. **Isolation**: every namespace has `block-agents` when a light node exists (`kubectl get networkpolicy -A`);
    SSH offers only `publickey` (`ssh -o PreferredAuthentications=none -p $ANVIL_SSH_PORT core@$ANVIL_SERVER_IP` lists
    `publickey` alone).
12. **The autopilot can't do more than its repairs**: as the owner,
    `kubectl --as=system:serviceaccount:autopilot-access:autopilot get secrets -A` → Forbidden, and
    `... -n anvil-demo set env deploy/anvil-demo-web X=1 --from=secret/anvil-demo` → refused. The viewer at
    `https://$ANVIL_TAILNET_HOST:8446` lists the runs; Grafana's overview starts with the autopilot.
13. **Scale-out is ready but off**: `scripts/pool status` shows every pool at count 0 (nothing billed); atlas logs only
    the movable databases (`SHOW VARIABLES LIKE 'binlog_do_db'` as root inside the pod: `anvil_demo`).
14. Write the report to `docs/verify-<date>.md` (no secrets) and tell the owner what, if anything, is red.
