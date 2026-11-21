#!/usr/bin/env python3
"""Build every Kubernetes Secret from anvil.env, apps/<ns>/prod.env and sites.yaml (gitignored output files).

  <dir>/secret.yaml         per namespace: the registry pull secret + that namespace's own secrets
  <dir>/atlas-db.yaml       per namespace with a `db:`: DB_HOST, DB_PORT, DB_NAME, DB_USER (<ns>_rw), DB_PASSWORD
  <dir>/server-backup.yaml  atlas (and any app with a backup CronJob): bucket, write-only key, alert email
<dir> is platform/<ns> or apps/<ns>. `scripts/node.sh deploy <ns>` applies them before the app.
Holds no secret values itself. Run from anywhere: python3 -I scripts/make-secrets.py
"""
import base64, json, os, pathlib, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I leaves the script's folder off sys.path
import anvil_env  # noqa: E402
import sites  # noqa: E402

import yaml  # noqa: E402

REPO = anvil_env.REPO
os.chdir(REPO)
E = anvil_env.load()
DATA = REPO / ".data"
missing = []


def need(*keys):
    out = {}
    for k in keys:
        if E.get(k):
            out[k] = E[k]
        else:
            missing.append(k)
    return out


def secret(ns, name, data, type_="Opaque"):
    # JSON is valid YAML and quotes every value safely.
    return json.dumps({"apiVersion": "v1", "kind": "Secret", "type": type_,
                       "metadata": {"name": name, "namespace": ns,
                                    "labels": {"app.kubernetes.io/part-of": ns, "app.kubernetes.io/managed-by": "anvil"}},
                       "stringData": data}, indent=2)


def pull_secret(ns):
    """anvil-registry: lets the node pull our own images (Scaleway registry, user nologin)."""
    host = E.get("ANVIL_REGISTRY", "").split("/")[0]
    auth = base64.b64encode(f"nologin:{E.get('SCW_SECRET_KEY', '')}".encode()).decode()
    cfg = json.dumps({"auths": {host: {"username": "nologin", "password": E.get("SCW_SECRET_KEY", ""), "auth": auth}}})
    return json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/dockerconfigjson",
                       "metadata": {"name": "anvil-registry", "namespace": ns}, "data": {
                           ".dockerconfigjson": base64.b64encode(cfg.encode()).decode()}}, indent=2)


def write(path, docs):
    p = pathlib.Path(path)
    p.write_text("\n---\n".join(docs) + "\n")
    p.chmod(0o600)


status_code, webhook_token = E.get("STATUS_CODE", ""), E.get("WEBHOOK_TOKEN", "")
nss = sites.namespaces()
# scripted namespaces (a load-test copy) get their secrets from the script that makes them
out = {ns: [pull_secret(ns)] for ns, v in nss.items() if ns not in ("origin-ca", "www") and not v.get("scripted")}

# --- apps: apps/<ns>/prod.env -> Secret <ns> (every key) ------------------------------------------------------------
for ns in nss:
    envp = REPO / sites.nsdir(ns) / "prod.env"
    if envp.exists():
        vals = anvil_env.parse(envp)
        gaps = [k for k in sites.generated(ns) if not vals.get(k)]
        if gaps:
            missing += [f"{ns}:{k}" for k in gaps]
        out.setdefault(ns, []).append(secret(ns, ns, vals))
    elif sites.generated(ns):
        missing.append(f"{sites.nsdir(ns)}/prod.env (run scripts/anvil-secrets init)")

# --- origin-ca: one TLS secret per zone, in kube-system (Traefik's default TLSStore) --------------------------------
tls = []
for z in sites.zones():
    crt, key = DATA / "origin-ca" / f"{z}.crt", DATA / "origin-ca" / f"{z}.key"
    if crt.exists() and key.exists():
        tls.append(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/tls",
                               "metadata": {"name": sites.tls_secret(z), "namespace": "kube-system"},
                               "stringData": {"tls.crt": crt.read_text(), "tls.key": key.read_text()}}, indent=2))
    else:
        missing.append(f".data/origin-ca/{z}.crt (run scripts/origin-certs.py)")
if tls:
    write("platform/origin-ca/secret.yaml", tls)

# --- atlas: root, and one atlas-db secret per project with a database -----------------------------------------------
out["atlas"].append(secret("atlas", "atlas-root", {"MARIADB_ROOT_PASSWORD": E.get("ATLAS_ROOT_PASSWORD", "")}))
need("ATLAS_ROOT_PASSWORD", "ATLAS_BACKUP_PASSWORD", "HEALTH_DB_PASSWORD")
for ns, db in sites.dbs().items():
    key = ns.upper().replace("-", "_")
    pw = need(f"{key}_RW_PASSWORD").get(f"{key}_RW_PASSWORD", "")
    write(f"{sites.nsdir(ns)}/atlas-db.yaml", [secret(ns, "atlas-db", {
        # db_host: set by scripts/move-db use-alias (the alias a cutover flips) while a database can move
        "DB_HOST": nss[ns].get("db_host") or "atlas-mariadb.atlas", "DB_PORT": "3306", "DB_NAME": db,
        "DB_USER": f"{ns.replace('-', '_')}_rw",
        "DB_PASSWORD": pw})])

# --- webhook: status code + token; health-watch (posts problems, logs in to the DB as `health`) ---------------------
need("STATUS_CODE", "WEBHOOK_TOKEN", "ALERT_SERVICE_PASSWORD")
out["webhook"] += [
    secret("webhook", "webhook-auth", {"WEBHOOK_TOKEN": webhook_token, "STATUS_CODE": status_code,
                                       "ALERT_SERVICE_PASSWORD": E.get("ALERT_SERVICE_PASSWORD", "")}),
    secret("webhook", "health-watch", {"WEBHOOK_URL": "http://webhook.webhook:9000/error_arduino",
                                       "WEBHOOK_TOKEN": webhook_token, "STATUS_CODE": status_code,
                                       "HEALTH_DB_HOST": "atlas-mariadb.atlas", "HEALTH_DB_USER": "health",
                                       "MYSQL_PWD": E.get("HEALTH_DB_PASSWORD", "")})]


# --- alerting: Prometheus + Alertmanager configs (they hold secrets), twilio-alert's env, Grafana admin -------------
def probe_job(job, by_url):
    by_ns = {}
    for u, ns in by_url.items():
        by_ns.setdefault(ns, []).append(u)
    return {"job_name": job, "metrics_path": "/probe", "params": {"module": ["http_2xx"]}, "scrape_interval": "30s",
            "static_configs": [{"targets": us, "labels": {"namespace": ns}} for ns, us in sorted(by_ns.items())],
            "relabel_configs": [{"source_labels": ["__address__"], "target_label": "__param_target"},
                                {"source_labels": ["__param_target"], "target_label": "instance",
                                 "regex": "([^?]*).*", "replacement": "${1}"},
                                {"target_label": "__address__", "replacement": "alerting-blackbox:9115"}]}


app_metrics = []
for ns, v in nss.items():
    for target in v.get("metrics", []):
        hostport, _, path = target.partition("/")
        app_metrics.append({"job_name": f"{ns}-{hostport.split('.')[0]}", "metrics_path": "/" + path,
                            "scrape_interval": "30s",
                            "static_configs": [{"targets": [hostport], "labels": {"namespace": ns}}]})
prom = {
    "global": {"scrape_interval": "30s", "evaluation_interval": "30s"},
    "alerting": {"alertmanagers": [{"static_configs": [{"targets": ["alerting-alertmanager:9093"]}]}]},
    "rule_files": ["/etc/prometheus/rules/alerts.yml"],
    "scrape_configs": [
        {"job_name": "prometheus", "static_configs": [{"targets": ["localhost:9090"]}]},
        {"job_name": "blackbox", "static_configs": [{"targets": ["alerting-blackbox:9115"]}]},
        # every workload's state (stuck pods, unavailable services, failed jobs): the cluster-wide rules
        # the nodes themselves (alerting-node-exporter: one unprivileged pod per node, found through a read-only Role
        # on pods in alerting): CPU incl. steal, memory, pressure, load, disk
        {"job_name": "node", "scrape_interval": "30s",
         "kubernetes_sd_configs": [{"role": "pod", "namespaces": {"names": ["alerting"]}}],
         "relabel_configs": [
             {"source_labels": ["__meta_kubernetes_pod_label_app"], "regex": "alerting-node-exporter", "action": "keep"},
             {"source_labels": ["__meta_kubernetes_pod_ip"], "target_label": "__address__", "replacement": "${1}:9101"},
             {"source_labels": ["__meta_kubernetes_pod_node_name"], "target_label": "node"}]},
        # Traefik's own counts per site (service) and status code, and its response times: the failed-requests and
        # slow-site alerts. Only those two families are kept (~1,000-1,500 series).
        # Every Traefik: the server's and a pool's direct-mode one (traefik-pool-<name>), found by label in kube-system.
        {"job_name": "traefik", "scrape_interval": "30s",
         "kubernetes_sd_configs": [{"role": "pod", "namespaces": {"names": ["kube-system"]}}],
         "relabel_configs": [
             {"source_labels": ["__meta_kubernetes_pod_label_app_kubernetes_io_name"], "regex": "traefik|traefik-pool-.+", "action": "keep"},
             {"source_labels": ["__meta_kubernetes_pod_ip"], "target_label": "__address__", "replacement": "${1}:9100"},
             {"source_labels": ["__meta_kubernetes_pod_node_name"], "target_label": "node"}],
         "metric_relabel_configs": [{"source_labels": ["__name__"], "action": "keep",
                                     "regex": "traefik_service_requests_total|traefik_service_request_duration_seconds_bucket"}]},
        # MariaDB replication status (alerting-mysqld-exporter, the atlas_monitor login: status only, no data): atlas,
        # and each project's own database server while it is moved (scripts/move-db). The moved-database alerts.
        {"job_name": "mariadb", "metrics_path": "/probe", "scrape_interval": "30s", "params": {"auth_module": ["client"]},
         "static_configs": [{"targets": ["atlas-mariadb.atlas:3306"] + [f"{ns}-mariadb.{ns}:3306" for ns in sorted(sites.moves())]}],
         "relabel_configs": [{"source_labels": ["__address__"], "target_label": "__param_target"},
                             {"source_labels": ["__param_target"], "target_label": "instance"},
                             {"target_label": "__address__", "replacement": "alerting-mysqld-exporter:9104"}]},
        {"job_name": "kube-state-metrics", "scrape_interval": "30s",
         "static_configs": [{"targets": ["alerting-kube-state-metrics:8080"]}]},
        # the autopilot on the home machine (state, runs, heartbeat), as reported to webhookd every 15 s
        {"job_name": "autopilot", "metrics_path": "/autopilot_metrics", "scrape_interval": "30s",
         "params": {"code": [status_code]}, "static_configs": [{"targets": ["webhook.webhook:9000"]}]},
        probe_job("sites", sites.probes()),
        probe_job("overall", {f"https://status.{E.get('ANVIL_DOMAIN', '')}/overall?code={status_code}": "webhook"}),
    ] + app_metrics,
}
am = {
    # The phone schedule (bursts, quiet hours, a pause after you answer) lives in twilio-alert: Alertmanager only tells
    # it what's firing (re-sent every 5 min) and what has resolved.
    "route": {"receiver": "phone", "group_by": ["alertname", "instance"], "group_wait": "30s", "group_interval": "1m",
              "repeat_interval": "5m",
              # Watchdog always fires: Alertmanager's heartbeat to webhookd (/am_heartbeat), read by the home watchdog
              "routes": [{"matchers": ['alertname="Watchdog"'], "receiver": "heartbeat", "group_wait": "0s",
                          "group_interval": "1m", "repeat_interval": "15m"},
                         # severity="notify": to look at soon, not a phone call: one line a day per alert and site on
                         # the error latch (webhookd's am_latch hook). severity="warning": shown, never sent.
                         {"matchers": ['severity="notify"'], "receiver": "latch", "repeat_interval": "6h"},
                         {"matchers": ['severity="warning"'], "receiver": "quiet"}]},
    "receivers": [
        {"name": "phone", "webhook_configs": [{"url": "http://alerting-twilio:3000/alert?password="
                                               + E.get("ALERT_SERVICE_PASSWORD", ""), "send_resolved": True}]},
        {"name": "latch", "webhook_configs": [{"url": f"http://webhook.webhook:9000/am_latch?token={webhook_token}",
                                               "send_resolved": False}]},
        {"name": "quiet"},
        {"name": "heartbeat", "webhook_configs": [{"url": f"http://webhook.webhook:9000/am_heartbeat?token={webhook_token}",
                                                   "send_resolved": False}]}],
}
tw = need("TWILIO_ACCOUNT_SID", "TWILIO_API_KEY", "TWILIO_API_SECRET", "TWILIO_PHONE_NUMBER", "ANVIL_OWNER_PHONE",
          "GRAFANA_ADMIN_PASSWORD")
out["alerting"] += [
    secret("alerting", "alerting-config", {"prometheus.yml": yaml.safe_dump(prom, sort_keys=False),
                                           "alertmanager.yml": yaml.safe_dump(am, sort_keys=False)}),
    secret("alerting", "twilio-env", {"TWILIO_ACCOUNT_SID": tw.get("TWILIO_ACCOUNT_SID", ""),
                                      "TWILIO_API_KEY": tw.get("TWILIO_API_KEY", ""),
                                      "TWILIO_API_SECRET": tw.get("TWILIO_API_SECRET", ""),
                                      "TWILIO_PHONE_NUMBER": tw.get("TWILIO_PHONE_NUMBER", ""),
                                      "ALERT_NUMBER": tw.get("ANVIL_OWNER_PHONE", ""),
                                      "SERVICE_PASSWORD": E.get("ALERT_SERVICE_PASSWORD", "")}),
    secret("alerting", "grafana-admin", {"GRAFANA_ADMIN_PASSWORD": E.get("GRAFANA_ADMIN_PASSWORD", "")}),
    secret("alerting", "mysqld-exporter", {"my.cnf": f"[client]\nuser=atlas_monitor\npassword={E.get('ATLAS_MONITOR_PASSWORD', '')}\n"})]
need("ATLAS_MONITOR_PASSWORD")

# --- edge-purger: its own purge-only Cloudflare token (optional) + the read-only password of each database it watches
_pd = {"CLOUDFLARE_PURGE_TOKEN": E.get("CLOUDFLARE_PURGE_TOKEN", "")}
for _ns, _v in nss.items():
    _pc = (_v.get("edge_cache") or {}).get("purge_on_change") if _v.get("edge_cache") else None
    if _pc:
        _k = f"{_ns.upper().replace('-', '_')}_RO_PASSWORD"
        _pd[f"DB_PW_{_pc['db']}"] = need(_k).get(_k, "")
if "edge-warmer" in out:
    out["edge-warmer"].append(secret("edge-warmer", "edge-purger", _pd))

# --- off-site backups: atlas (every database) --------------------------------------------------------------------
bk = need("BACKUP_BUCKET", "BACKUP_S3_ACCESS_KEY", "BACKUP_S3_SECRET_KEY", "ANVIL_OWNER_EMAIL", "SCW_DEFAULT_PROJECT_ID")
write("platform/atlas/server-backup.yaml", [secret("atlas", "server-backup", {
    "BACKUP_BUCKET": bk.get("BACKUP_BUCKET", ""), "BACKUP_REGION": E.get("ANVIL_REGION", "fr-par"),
    "BACKUP_S3_ACCESS_KEY": bk.get("BACKUP_S3_ACCESS_KEY", ""), "BACKUP_S3_SECRET_KEY": bk.get("BACKUP_S3_SECRET_KEY", ""),
    "TEM_PROJECT_ID": bk.get("SCW_DEFAULT_PROJECT_ID", ""), "ALERT_TO": bk.get("ANVIL_OWNER_EMAIL", ""),
    "ALERT_FROM": f"backups@{E.get('ANVIL_DOMAIN', '')}", "PLATFORM_NAME": E.get("ANVIL_NAME", "anvil"),
    "WEBHOOK_URL": "http://webhook.webhook:9000/error_arduino", "WEBHOOK_TOKEN": webhook_token,
    "DB_HOST": "atlas-mariadb.atlas", "DB_USER": "atlas_backup", "MYSQL_PWD": E.get("ATLAS_BACKUP_PASSWORD", "")})])

for ns, docs in out.items():
    write(f"{sites.nsdir(ns)}/secret.yaml", docs)

if missing:
    print("NOT SET (the secrets above were written with empty values; fill them, then re-run):\n  "
          + "\n  ".join(sorted(set(missing))))
    sys.exit(1)
print(f"secrets written for {len(out)} namespaces")
