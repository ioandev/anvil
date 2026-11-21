#!/usr/bin/env bash
# Operate the server over SSH (kubectl lives on the box; nothing to install locally).
#   scripts/node.sh ssh [cmd...]          run a command as core
#   scripts/node.sh kubectl [args...]     sudo kubectl on the box (stdin passes through)
#   scripts/node.sh deploy <ns>...        ConfigMaps (sites.yaml) + generated secrets + {platform,apps}/<ns>/app.yaml,
#                                         rendered with ${ANVIL_*} from anvil.env; then restarts only workloads whose
#                                         config changed (rule 16)
#   scripts/node.sh deploy-all            every namespace in sites.yaml (platform first)
#   scripts/node.sh diff <ns>...          kubectl diff of the rendered manifest against the cluster (changes nothing)
#   scripts/node.sh atlas-users           (re)apply every project's _rw/_ro users, the backup and health users
#   scripts/node.sh restore-db <ns>       load .data/<ns>/db.sql.gz into the shared MariaDB (atlas)
#   scripts/node.sh curl <host> [path]    hit a site through Traefik on the box, with the origin-pull client cert
#   scripts/node.sh load-pvc <ns> <pvc> <uid> <tgz> [member...]   unpack a tarball into a PVC (throwaway pod)
#   scripts/node.sh run-job <ns> <job.yaml> [args...]              (re)run a one-off Job, wait, show its log
#   scripts/node.sh grafana on|off       Grafana (~230 MB) only while you use it
#   scripts/node.sh autopilot-kubeconfig  print the autopilot's narrow kubeconfig (for OpenBao; never into the repo)
#   scripts/node.sh isolate-agents       block-agents NetworkPolicy in every namespace (deploy does it per namespace)
#   scripts/node.sh swap [MiB]           show the swap, or resize it everywhere (anvil.env + the live node)
#   scripts/node.sh disk                  root disk usage
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; [[ -f anvil.env ]] && . ./anvil.env; set +a

KEY=${ANVIL_SSH_KEY:-$HOME/.ssh/id_ed25519_anvil}
IP=${ANVIL_SERVER_IP:-$(terraform -chdir=infra output -raw public_ip)}
SSH_PORT=${ANVIL_SSH_PORT:-$(terraform -chdir=infra output -raw ssh_port 2>/dev/null || echo 22)}
DATA=${ANVIL_DATA_DIR:-.data}
SSH=(ssh -i "$KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "core@$IP")

# ssh joins its arguments into one string for the remote shell, so re-quote them; otherwise the node expands $VARS
# and redirects meant for the pod.
k() { "${SSH[@]}" sudo /opt/bin/kubectl "$(printf '%q ' "$@")"; }
sites() { python3 -I scripts/sites.py "$@"; }
nsdir() { if [[ -d "platform/$1" ]]; then echo "platform/$1"; else echo "apps/$1"; fi; }

# confighash <ns>: restart each Deployment/StatefulSet whose Secrets/ConfigMaps changed since the last call.
confighash() {
  local ns=$1
  k -n "$ns" get deploy,sts,configmap,secret -o json | python3 -I -c '
import json, sys, hashlib
items = json.load(sys.stdin)["items"]
data = {(i["kind"], i["metadata"]["name"]): json.dumps([i.get("data"), i.get("binaryData"), i.get("stringData")], sort_keys=True)
        for i in items if i["kind"] in ("ConfigMap", "Secret")}
for w in items:
    if w["kind"] not in ("Deployment", "StatefulSet"):
        continue
    spec = w["spec"]["template"]["spec"]
    refs = set()
    for v in spec.get("volumes", []):
        if "configMap" in v: refs.add(("ConfigMap", v["configMap"]["name"]))
        if "secret" in v: refs.add(("Secret", v["secret"]["secretName"]))
        for s in v.get("projected", {}).get("sources", []):
            if "configMap" in s: refs.add(("ConfigMap", s["configMap"]["name"]))
            if "secret" in s: refs.add(("Secret", s["secret"]["name"]))
    for c in spec.get("containers", []) + spec.get("initContainers", []):
        for e in c.get("envFrom", []):
            if "configMapRef" in e: refs.add(("ConfigMap", e["configMapRef"]["name"]))
            if "secretRef" in e: refs.add(("Secret", e["secretRef"]["name"]))
        for e in c.get("env", []):
            vf = e.get("valueFrom", {})
            if "configMapKeyRef" in vf: refs.add(("ConfigMap", vf["configMapKeyRef"]["name"]))
            if "secretKeyRef" in vf: refs.add(("Secret", vf["secretKeyRef"]["name"]))
    if not refs:
        continue
    h = hashlib.sha256("".join(k + "/" + n + "=" + data.get((k, n), "missing") for k, n in sorted(refs)).encode()).hexdigest()[:16]
    old = w["metadata"].get("annotations", {}).get("anvil/config-hash")
    kind = "deploy" if w["kind"] == "Deployment" else "sts"
    if old != h:
        print(kind, w["metadata"]["name"], h, "restart" if old else "record")
' | while read -r kind name hash action; do
    k -n "$ns" annotate "$kind/$name" "anvil/config-hash=$hash" --overwrite </dev/null >/dev/null
    if [[ "$action" == restart ]]; then
      k -n "$ns" rollout restart "$kind/$name" </dev/null >/dev/null && echo "config changed: restarted $ns/$name"
    fi
  done
}

# configmaps <ns>: the ConfigMaps sites.yaml declares for it (`configmaps: {name: folder-or-file}`), as YAML
configmaps() {
  python3 -I - "$1" <<'PY'
import json, pathlib, sys
sys.path.insert(0, "scripts"); import sites
ns = sys.argv[1]
items = []
for name, path in sites.configmaps(ns).items():
    p = pathlib.Path(path)
    files = sorted(f for f in p.iterdir() if f.is_file()) if p.is_dir() else [p]
    items.append({"apiVersion": "v1", "kind": "ConfigMap",
                  "metadata": {"name": name, "namespace": ns,
                               "labels": {"app.kubernetes.io/part-of": ns, "app.kubernetes.io/managed-by": "anvil"}},
                  "data": {f.name: f.read_text() for f in files}})
# One List: kubectl reads JSON objects separated by "---" as broken JSON once there are two of them.
if items: print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
PY
}

# isolate_agents <ns>...: a block-agents NetworkPolicy refusing traffic from the light node's pod range and address
# (label anvil/role=light), so even root there can't reach the apps or the database; only kube-system (DNS) stays
# open. Pods meant to run on the light node label themselves anvil/light=true and are left out. Without a light node
# the policy is removed. Enforced on the master (k3s's network policy controller).
isolate_agents() {
  local except
  # The light node, and any pool marked untrusted (trusted pools hold Secrets and must reach the database and apps).
  except=$({ k get nodes -l anvil/role=light -o json </dev/null; k get nodes -l 'anvil/pool,!anvil/trusted' -o json </dev/null; } | python3 -c '
import json, sys
dec, text, i = json.JSONDecoder(), sys.stdin.read(), 0
docs = []
while i < len(text.strip()):
    while text[i].isspace(): i += 1
    d, i = dec.raw_decode(text, i); docs.append(d)
for n in [x for d in docs for x in d["items"]]:
    if n["spec"].get("podCIDR"): print(n["spec"]["podCIDR"])
    for a in n["status"]["addresses"]:
        if a["type"] == "InternalIP": print(a["address"] + "/32")')
  for ns in "$@"; do
    [[ $ns == kube-system ]] && continue
    if [[ -z $except ]]; then k -n "$ns" delete networkpolicy block-agents --ignore-not-found >/dev/null; continue; fi
    python3 -I - "$ns" $except <<'PY' | k apply -f - >/dev/null
import json, sys
ns, ranges = sys.argv[1], sys.argv[2:]
print(json.dumps({"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
    "metadata": {"name": "block-agents", "namespace": ns, "labels": {"app.kubernetes.io/part-of": ns,
        "app.kubernetes.io/managed-by": "anvil", "anvil/tier": "platform"}},
    "spec": {"podSelector": {"matchExpressions": [{"key": "anvil/light", "operator": "DoesNotExist"}]},
             "policyTypes": ["Ingress"],
             "ingress": [{"from": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": ranges}}]}]}}))
PY
  done
}

deploy() {
  local ns=$1 dir manifest
  dir=$(nsdir "$ns")
  manifest=$(sites manifest "$ns") || { echo "deploy $ns: rendering failed" >&2; return 1; }
  k apply -f - <<<"$manifest" >/dev/null 2>&1 || true        # first pass creates the namespace
  local maps; maps=$(configmaps "$ns")
  [[ -z "$maps" ]] || k apply -f - <<<"$maps"
  local f
  for f in secret.yaml atlas-db.yaml server-backup.yaml; do
    [[ -f "$dir/$f" ]] && k apply -f - < "$dir/$f"
  done
  k apply -f - <<<"$manifest"
  isolate_agents "$ns"
  confighash "$ns"
}

cmd=${1:?usage: see the header of scripts/node.sh}; shift
case "$cmd" in
  ssh) "${SSH[@]}" "$@" ;;
  kubectl) k "$@" ;;
  disk) "${SSH[@]}" 'lsblk; df -h / /var' ;;
  grafana)
    # grafana on|off: Grafana uses ~230 MB, so it's off unless you're looking at dashboards (tailnet :3443).
    case "${1:-}" in
      on)  k -n alerting scale deploy/alerting-grafana --replicas=1 && k -n alerting rollout status deploy/alerting-grafana --timeout=180s ;;
      off) k -n alerting scale deploy/alerting-grafana --replicas=0 ;;
      *)   echo "usage: scripts/node.sh grafana on|off"; exit 1 ;;
    esac ;;

  swap)
    # swap [MiB]: without a size, show the configured and the live swap. With one, change it everywhere:
    #   1. ANVIL_SWAP_MB in anvil.env (the Makefile passes it to Terraform: Butane's create-swapfile.service on a new
    #      server; the live server's user_data follows at the next make apply, in place, nothing replaced);
    #   2. the live node: the size in /etc/systemd/system/create-swapfile.service, then the swapfile itself is turned
    #      off, deleted and created again at the new size, without a reboot. Turning swap off first moves what's in
    #      it back into memory, so it refuses when that wouldn't fit.
    conf=${ANVIL_SWAP_MB:-$(sed -n '/variable "swap_size_mb"/,/^}/s/^ *default *= *\([0-9]*\).*/\1/p' infra/variables.tf)}
    live() { "${SSH[@]}" 'swapon --show --noheadings --bytes | awk "{s+=\$3; u+=\$4} END {printf \"%d MiB, %d MiB used\", s/1048576, u/1048576}"
                          sed -n "s/.*--size \([0-9]*\)m.*/, unit says \1 MiB/p" /etc/systemd/system/create-swapfile.service' </dev/null | tr -d '\n'; echo; }
    if [[ -z ${1:-} ]]; then echo "configured: ${conf} MiB (anvil.env ANVIL_SWAP_MB / variables.tf)"; echo "live: $(live)"; exit 0; fi
    size=$1
    [[ $size =~ ^[0-9]+$ ]] && (( size >= 256 && size <= 16384 )) || { echo "size in MiB, 256 to 16384"; exit 1; }
    free_mb=$("${SSH[@]}" 'df -m --output=avail /var | tail -1' </dev/null | tr -d ' ')
    (( free_mb > size + 10240 )) || { echo "/var has ${free_mb} MiB free: not enough for ${size} MiB of swap plus 10 GB to spare"; exit 1; }
    # 1. the setting
    if grep -q '^ANVIL_SWAP_MB=' anvil.env; then sed -i -E "s/^ANVIL_SWAP_MB=[0-9]+/ANVIL_SWAP_MB=$size/" anvil.env
    else printf 'ANVIL_SWAP_MB=%s                    # swapfile (MiB); resize with scripts/node.sh swap <MiB>\n' "$size" >> anvil.env; fi
    grep -q "^ANVIL_SWAP_MB=$size\b" anvil.env; echo "anvil.env: ANVIL_SWAP_MB=$size (was $conf)"
    # 2. the live node
    "${SSH[@]}" "set -e
      used=\$(free -m | awk '/^Swap:/ {print \$3}'); avail=\$(free -m | awk '/^Mem:/ {print \$7}')
      [ \$((used + 512)) -lt \$avail ] || { echo \"swap holds \${used} MiB and only \${avail} MiB of memory is available: not turning it off\"; exit 1; }
      f=/etc/systemd/system/create-swapfile.service
      sudo sed -i -E 's/[0-9]+MiB swapfile/${size}MiB swapfile/; s/--size [0-9]+m/--size ${size}m/' \$f
      grep -q -- '--size ${size}m' \$f
      sudo systemctl daemon-reload
      sudo systemctl stop var-swapfile.swap
      sudo rm -f /var/swapfile
      sudo systemctl restart create-swapfile.service
      sudo systemctl start var-swapfile.swap
      systemctl is-active --quiet var-swapfile.swap" </dev/null
    echo "live: $(live)"
    "${SSH[@]}" 'swapon --show --noheadings --bytes' </dev/null | awk -v want="$size" '{s+=$3} END {exit !(int(s/1048576) >= want - 1)}' \
      || { echo "the live swap isn't ${size} MiB: check systemctl status create-swapfile.service var-swapfile.swap"; exit 1; }
    echo "done. Still to do: make plan && make apply (in-place user_data change), then make secrets-encrypt (anvil.env)" ;;

  autopilot-kubeconfig)
    # The autopilot's narrow cluster login (platform/autopilot-access): a kubeconfig for its ServiceAccount, reaching
    # the API over the tailnet (https://$ANVIL_TAILNET_HOST:6443; 6443 is closed to the internet), the server's cert
    # checked against the name every k3s API cert carries (`kubernetes`). Printed to stdout: the 70-autopilot step
    # puts it in OpenBao (ops/kube/autopilot, field kubeconfig). Never write it to the repo.
    : "${ANVIL_TAILNET_HOST:?set ANVIL_TAILNET_HOST in anvil.env}"
    tok=$(k -n autopilot-access get secret autopilot-token -o jsonpath='{.data.token}' </dev/null | base64 -d)
    ca=$(k -n autopilot-access get secret autopilot-token -o jsonpath='{.data.ca\.crt}' </dev/null)
    [[ -n $tok && -n $ca ]] || { echo "no token yet: scripts/node.sh deploy autopilot-access first" >&2; exit 1; }
    cat <<KC
apiVersion: v1
kind: Config
clusters:
  - name: ${ANVIL_NAME:-anvil}
    cluster: { server: "https://${ANVIL_TAILNET_HOST}:6443", certificate-authority-data: "$ca", tls-server-name: kubernetes }
users:
  - name: autopilot
    user: { token: "$tok" }
contexts:
  - name: autopilot
    context: { cluster: ${ANVIL_NAME:-anvil}, user: autopilot }
current-context: autopilot
KC
    ;;

  isolate-agents)
    # Apply (or, with no light node, remove) block-agents in every namespace. deploy does it per namespace; run this
    # after the light node is added or replaced (its pod range can change).
    isolate_agents $(k get ns -o json </dev/null | python3 -c 'import json,sys; print(" ".join(n["metadata"]["name"] for n in json.load(sys.stdin)["items"] if n["status"].get("phase") == "Active"))')
    k get networkpolicy -A --no-headers </dev/null | awk '$2 == "block-agents"' | wc -l | sed 's/$/ namespaces isolated from the light node/' ;;

  deploy)
    # Our own deploys look like incidents for a few minutes (a rollout, a dependency restarting): pause the autopilot
    # for 10 minutes so it doesn't investigate them. Phone alerts stay on, so a deploy that really breaks something
    # still calls. Best effort; NO_AUTOPILOT_PAUSE=1 skips it (then resume isn't needed either).
    if [[ -z ${NO_AUTOPILOT_PAUSE:-} && -n ${STATUS_CODE:-} && -n ${ANVIL_DOMAIN:-} ]]; then
      curl -s -o /dev/null -m 10 "https://status.$ANVIL_DOMAIN/autopilot_pause?minutes=10&code=$STATUS_CODE" </dev/null || true
    fi
    for ns in "$@"; do
      deploy "$ns"
      # Edge cache: once the new pods serve, purge the site's Cloudflare zone so long edge TTLs never hide a release
      # (the edge-warmer refills the main pages). From this machine: the Cloudflare token never goes to the server.
      # NO_EDGE_PURGE=1 skips it.
      if [[ -z ${NO_EDGE_PURGE:-} ]]; then
        _zones=$(python3 -I scripts/cloudflare-purge --zones-for "$ns" 2>/dev/null || true)
        if [[ -n $_zones ]]; then
          for _d in $(k -n "$ns" get deploy -o name 2>/dev/null); do k -n "$ns" rollout status "$_d" --timeout=300s >/dev/null 2>&1 || true; done
          python3 -I scripts/cloudflare-purge --ns "$ns" || true
        fi
      fi
    done ;;

  deploy-all)
    # platform first (origin-ca before anything serves TLS, atlas before apps with a database), then the apps
    order=$(python3 -I - <<'PY'
import sys; sys.path.insert(0, "scripts"); import sites
first = ["origin-ca", "atlas", "webhook", "alerting", "www", "dozzle"]
nss = sites.namespaces()
print(" ".join([n for n in first if n in nss] + [n for n, v in nss.items() if n not in first and v["tier"] == "platform"]
               + [n for n, v in nss.items() if v["tier"] == "app" and not v.get("scripted")]))   # scripted: made by a script
PY
)
    for ns in $order; do echo "== $ns"; deploy "$ns"; done ;;

  diff)
    for ns in "$@"; do sites manifest "$ns" | k diff -f - || true; done ;;

  curl)
    # curl <host> [path] [curl args...]: request a site THROUGH Traefik on the box, presenting the origin-pull client
    # cert (without it the handshake is refused: only Cloudflare may connect). Prints status + time.
    host=${1:?host} path=${2:-/}; shift; [[ $# -gt 0 ]] && shift
    aop=$DATA/cloudflare-aop
    extra=""; [[ $# -gt 0 ]] && extra=$(printf '%q ' "$@")
    { cat "$aop/client.crt"; cat "$aop/client.key"; } | "${SSH[@]}" "umask 077; f=\$(mktemp); cat > \$f; curl -sk --cert \$f -o /dev/null -w '$host$path %{http_code} %{time_total}s\n' --resolve $host:443:127.0.0.1 $extra https://$host$path; rm -f \$f" ;;

  load-pvc)
    ns=${1:?ns} pvc=${2:?pvc} uid=${3:?uid} tgz=${4:?tarball}; shift 4
    pod=zz-load-$pvc
    k -n "$ns" delete pod "$pod" --ignore-not-found >/dev/null
    python3 -I - "$ns" "$pod" "$pvc" "$uid" <<'PY' | k apply -f - >/dev/null
import json, sys
ns, pod, pvc, uid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
print(json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": pod, "namespace": ns},
  "spec": {"restartPolicy": "Never", "enableServiceLinks": False,
           "securityContext": {"runAsUser": uid, "runAsGroup": uid, "fsGroup": uid},
           "containers": [{"name": "load", "image": "busybox:1.37", "command": ["sleep", "600"],
                           "volumeMounts": [{"name": "v", "mountPath": "/v"}]}],
           "volumes": [{"name": "v", "persistentVolumeClaim": {"claimName": pvc}}]}}))
PY
    k -n "$ns" wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null
    k -n "$ns" exec -i "$pod" -- tar -C /v -xzf - "$@" < "$tgz" 2>&1 | grep -vE "^tar: \.: Cannot|can't preserve|Exiting with failure" || true
    k -n "$ns" exec "$pod" -- sh -c 'ls -lan /v | head -20; du -sh /v'
    k -n "$ns" delete pod "$pod" --wait=false >/dev/null ;;

  run-job)
    ns=${1:?ns} file=${2:?job.yaml}; shift 2
    job=$(python3 -I -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["metadata"]["name"])' "$file")
    k -n "$ns" delete job "$job" --ignore-not-found >/dev/null
    python3 -I - "$file" "$@" <<'PY' | k apply -f -
import json, sys, yaml
sys.path.insert(0, "scripts"); import anvil_env
d = yaml.safe_load(anvil_env.expand(open(sys.argv[1]).read(), where=sys.argv[1]))
c = d["spec"]["template"]["spec"]["containers"][0]
c["command"] = c.get("command", []) + sys.argv[2:]
print(json.dumps(d))
PY
    k -n "$ns" wait --for=condition=complete "job/$job" --timeout=300s || true
    k -n "$ns" logs "job/$job" --tail=50 ;;

  restore-db)
    # restore-db <ns>: import .data/<ns>/db.sql.gz (a `mariadb-dump --databases <db>`) into the shared MariaDB.
    # It replaces that one database and nothing else.
    ns=${1:?ns}
    db=$(sites db "$ns"); [[ -n "$db" ]] || { echo "$ns has no db in sites.yaml" >&2; exit 1; }
    pod=pod/atlas-mariadb-0
    k -n atlas wait --for=condition=Ready "$pod" --timeout=300s
    # Copy first, import second: streaming a big dump straight into `mariadb` through exec times out.
    gzip -dc "$DATA/$ns/db.sql.gz" | k -n atlas exec -i "$pod" -- sh -c 'cat > /tmp/restore.sql'
    k -n atlas exec "$pod" -- sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" < /tmp/restore.sql && rm /tmp/restore.sql'
    if [[ -f "$(nsdir "$ns")/post-restore.sql" ]]; then
      k -n atlas exec -i "$pod" -- sh -c "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" $db" < "$(nsdir "$ns")/post-restore.sql"
    fi
    "$0" atlas-users >/dev/null
    k -n atlas exec "$pod" -- sh -c "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" -e \"SELECT table_schema, COUNT(*) tables FROM information_schema.tables WHERE table_schema='$db' GROUP BY 1\"" ;;

  atlas-users)
    # Every project's _rw/_ro users with grants limited to its own database, the backup user (reads everything,
    # changes nothing) and `health` (can only log in: the status check). Idempotent; the SQL never touches disk.
    python3 -I - <<'PY' | k -n atlas exec -i pod/atlas-mariadb-0 -- sh -c 'mariadb --force -uroot -p"$MARIADB_ROOT_PASSWORD"'
import sys
sys.path.insert(0, "scripts"); import anvil_env, sites
env = anvil_env.load()
print("SET SESSION sql_log_bin = 0;")   # users and grants never go into the binary log (a moved server would replay them)
RW = ("SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES, CREATE TEMPORARY TABLES, "
      "LOCK TABLES, EXECUTE, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, TRIGGER, EVENT")
def user(u, pw):
    print(f"CREATE USER IF NOT EXISTS '{u}'@'%' IDENTIFIED BY '{pw}';")
    print(f"ALTER USER '{u}'@'%' IDENTIFIED BY '{pw}';")
for ns, db in sites.dbs().items():
    print(f"CREATE DATABASE IF NOT EXISTS `{db}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
    key, name = ns.upper().replace("-", "_"), ns.replace("-", "_")
    for kind, privs in (("rw", RW), ("ro", "SELECT, SHOW VIEW")):
        user(f"{name}_{kind}", env[f"{key}_{kind.upper()}_PASSWORD"])
        print(f"GRANT {privs} ON `{db}`.* TO '{name}_{kind}'@'%';")
# Live-sync logins (scripts/move-db): <ns>_repl for each project with `move:`. The binary log holds only those
# projects' databases (atlas's --binlog-do-db), so REPLICATION SLAVE (global by nature) shows nothing of the others;
# SELECT etc. only on the project's own database, for the first copy.
for ns in sites.moves():
    db = sites.dbs().get(ns)
    if not db:
        continue
    u, key = f"{ns.replace('-', '_')}_repl", ns.upper().replace("-", "_")
    user(u, env[f"{key}_REPL_PASSWORD"])
    print(f"GRANT REPLICATION SLAVE, BINLOG MONITOR ON *.* TO '{u}'@'%';")
    print(f"GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, SHOW CREATE ROUTINE ON `{db}`.* TO '{u}'@'%';")
# The replication alerts (alerting-mysqld-exporter): status only, no data, at most 3 connections.
mp = env["ATLAS_MONITOR_PASSWORD"]
print(f"CREATE USER IF NOT EXISTS 'atlas_monitor'@'%' IDENTIFIED BY '{mp}' WITH MAX_USER_CONNECTIONS 3;")
print(f"ALTER USER 'atlas_monitor'@'%' IDENTIFIED BY '{mp}' WITH MAX_USER_CONNECTIONS 3;")
print("GRANT PROCESS, BINLOG MONITOR, SLAVE MONITOR ON *.* TO 'atlas_monitor'@'%';")
user("atlas_backup", env["ATLAS_BACKUP_PASSWORD"])
print("GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, SHOW CREATE ROUTINE ON *.* TO 'atlas_backup'@'%';")
user("health", env["HEALTH_DB_PASSWORD"])   # USAGE only: can connect, can't read anything
print("FLUSH PRIVILEGES;")
PY
    echo "atlas users applied" ;;

  *) echo "unknown command $cmd (see the header of scripts/node.sh)"; exit 1 ;;
esac
