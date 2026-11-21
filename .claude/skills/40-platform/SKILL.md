---
name: 40-platform
description: Fifth anvil bootstrap step. Creates the registry namespace and the backup bucket and its write-only key, builds and pushes anvil's images, generates every Kubernetes Secret and deploys the shared platform (TLS, MariaDB, status webhooks, alerting, Grafana, Dozzle, backups). Use after 30-infra.
---

# 40-platform: the shared stack

1. **Registry**: create a private Scaleway container-registry namespace `$ANVIL_NAME-<random 6 hex>` in
   `$ANVIL_REGION` (`scw registry namespace create` or the API) →
   `scripts/anvil-secrets set ANVIL_REGISTRY=rg.$ANVIL_REGION.scw.cloud/<namespace>`.
2. **Backup bucket + key**: bucket `$ANVIL_NAME-backups-<random 6 hex>` (private) with lifecycle rules: `daily/`
   expires after 30 days, `monthly/` after 365. A dedicated IAM application `$ANVIL_NAME-backup` with
   **ObjectStorageObjectsWrite + TransactionalEmailEmailApiCreate only** (it can't read, list or delete: nothing on
   the server can remove old backups), API key **without expiry** → `BACKUP_BUCKET`, `BACKUP_S3_ACCESS_KEY`,
   `BACKUP_S3_SECRET_KEY` via `scripts/anvil-secrets set`. Verify the domain in Scaleway TEM (SPF/DKIM records in
   Cloudflare) so failure emails arrive.
3. **Images**: commit first (dirty builds are refused), then `make images` (anvil-backup, twilio-alert multi-arch,
   anvil-demo). Tags land in anvil.env.
4. **Secrets + deploy**: `make apps` = `make-secrets.py` then `node.sh deploy-all` (origin-ca, atlas, webhook,
   alerting, www, dozzle, then the apps). Then `scripts/node.sh atlas-users`.
5. Tailscale serve for the internal UIs on the node (Butane does it on first boot; check):
   `scripts/node.sh ssh sudo tailscale serve status` lists :8443 (Alertmanager), :9443 (Prometheus), :3443 (Grafana)
   and :443 (Dozzle).
6. Run the backup once: `scripts/node.sh kubectl -n atlas create job --from=cronjob/atlas-backup zz-first-backup`,
   wait, check the log, delete the job.

Verify: every pod Running/Ready (`kubectl get pods -A`), `python3 -I scripts/sites.py check` 0 errors, Grafana opens
on the tailnet, `https://status.$ANVIL_DOMAIN/space?code=…` (after the cutover in 50) is 200.
