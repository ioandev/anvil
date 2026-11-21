#!/bin/bash
# Every 15 minutes: posts a short line to the error latch (webhookd /error_arduino) for anything erroring on
# ${PLATFORM_NAME:-anvil}. Lines already in the latch aren't posted again, so it reads as a list, not a flood. Clear the latch
# with platform/webhook/clear-error-arduino.sh once things are fixed.
#   - a pod that can't start or keeps crashing (CrashLoopBackOff, ImagePullBackOff, config errors), or has been
#     running unready for over 10 minutes
#   - a Job that failed (once per job per day)
# It also reports the status behind /emails and /backups (200/500 endpoints the owner polls) every run.
# Env: WEBHOOK_URL, WEBHOOK_TOKEN (to post), STATUS_CODE (to read); HEALTH_DB_HOST, HEALTH_DB_USER, MYSQL_PWD (the login-only `health` user).
set -uo pipefail

api=https://kubernetes.default.svc
token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
k() { curl -sS -f -m 20 --cacert "$ca" -H "Authorization: Bearer $token" "$api$1"; }
now=$(date -u +%s); today=$(date -u +%F)
problems=()

# Pods. Job pods that finished (Succeeded/Failed) are covered by the Job check below.
pods="$(k /api/v1/pods)" || problems+=("health-watch: can't read pods")
while IFS=$'\t' read -r ns name reason since; do
  [ -n "$ns" ] || continue
  # Name the workload, not the pod (pod names change on every restart): drop ReplicaSet/StatefulSet suffixes.
  wl="$(echo "$name" | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//; s/-[0-9]+$//')"
  if [ "$reason" = Unready ]; then
    [ $(( now - $(date -u -d "$since" +%s) )) -gt 600 ] || continue
  fi
  problems+=("pod $ns/$wl: $reason")
done < <(echo "${pods:-{\}}" | jq -r '
  .items[]? | select(.status.phase != "Succeeded" and .status.phase != "Failed") |
  . as $p |
  ( [ .status.containerStatuses[]?, .status.initContainerStatuses[]? ] | map(.state.waiting.reason // empty)
    | map(select(. == "CrashLoopBackOff" or . == "ImagePullBackOff" or . == "ErrImagePull"
                 or . == "CreateContainerConfigError" or . == "CreateContainerError" or . == "InvalidImageName")) ) as $bad |
  if ($bad | length) > 0 then [$p.metadata.namespace, $p.metadata.name, $bad[0], ""] | @tsv
  elif $p.status.phase == "Running" and ([.status.conditions[]? | select(.type == "Ready" and .status == "False")] | length) > 0
    then [$p.metadata.namespace, $p.metadata.name, "Unready", ([.status.conditions[]? | select(.type == "Ready")][0].lastTransitionTime)] | @tsv
  else empty end' | sort -u)

# Jobs that failed in the last day (by CronJob name, so it's one line per job per day)
# Pool nodes (infra/pools.tf) are billed by the hour: once a day, a reminder for each one that has existed over 12 h
# (a rehearsal or load test is shorter; while a site is moved there, the reminder is expected).
nodes="$(k '/api/v1/nodes?labelSelector=anvil%2Fpool')" || problems+=("health-watch: can't read nodes")
while read -r name pool created; do
  [ -n "$name" ] || continue
  age=$(( (now - $(date -u -d "$created" +%s)) / 3600 ))
  [ "$age" -ge 12 ] && problems+=("pool node $name up ${age} h, billed hourly ($today): scripts/pool down $pool unless a site lives there")
done < <(echo "${nodes:-{\}}" | jq -r '.items[]? | "\(.metadata.name) \(.metadata.labels["anvil/pool"]) \(.metadata.creationTimestamp)"')
jobs="$(k /apis/batch/v1/jobs)" || problems+=("health-watch: can't read jobs")
while IFS=$'\t' read -r ns cj; do
  [ -n "$ns" ] && problems+=("job $ns/$cj failed $today")
done < <(echo "${jobs:-{\}}" | jq -r --argjson now "$now" '
  .items[]? | select(([.status.conditions[]? | select(.type == "Failed" and .status == "True")] | length) > 0) |
  select(($now - (.metadata.creationTimestamp | fromdateiso8601)) < 86400) |
  [.metadata.namespace, (.metadata.ownerReferences[0].name // .metadata.name)] | @tsv' | sort -u)

# Status reports for /database and /backups (each a plain 200/500 the owner's cron job polls)
base="${WEBHOOK_URL%/*}"
report() {  # report <name> <true|false> <detail>
  jq -n --argjson ok "$2" --arg d "$3" '{ok: $ok, detail: $d}' | curl -sS -f -m 20 -X POST -H "X-Token: $WEBHOOK_TOKEN" \
    -H "Content-Type: application/json" -d @- "$base/$1" >/dev/null || echo "could not report $1" >&2
}

# The shared database: a real login and query as `health` (a user that can only log in), reported for /database
if dbinfo="$(mariadb -h "$HEALTH_DB_HOST" -u "$HEALTH_DB_USER" -N --connect-timeout=10 -e \
     "SELECT CONCAT('login ok, MariaDB ', VERSION())" 2>&1)"; then
  report database true "$dbinfo"
else
  report database false "login/query failed: $(echo "$dbinfo" | head -n 1 | cut -c1-120)"
  problems+=("database: login/query failed")
fi


cjs="$(k /apis/batch/v1/cronjobs)" || cjs=""
bad=""; good=0
# every CronJob labelled app.kubernetes.io/component=backup (rule 17: labels), in any namespace
backups="$(echo "${cjs:-{\}}" | jq -r '.items[]? | select(.metadata.labels["app.kubernetes.io/component"] == "backup") | "\(.metadata.namespace)/\(.metadata.name)"')"
[ -n "$backups" ] || bad+="no backup CronJobs found; "
for item in $backups; do
  last="$(echo "${cjs:-{\}}" | jq -r --arg ns "${item%%/*}" --arg n "${item#*/}" \
    '[.items[]? | select(.metadata.namespace == $ns and .metadata.name == $n)][0] | if . == null then "missing" else (.status.lastSuccessfulTime // "never") end')"
  if [ "$last" = missing ] || [ "$last" = never ] || [ $(( (now - $(date -u -d "$last" +%s)) / 3600 )) -gt 26 ]; then
    bad+="${item#*/}: $last; "
  else
    good=$((good + 1))
  fi
done
if [ -z "$cjs" ]; then report backups false "can't read the backup jobs"
elif [ -n "$bad" ]; then report backups false "not backed up in 26h: ${bad%; }"
else report backups true "all $good backups succeeded in the last 26h"; fi

# Post what's new
current="$(curl -sS -m 20 "$WEBHOOK_URL?code=$STATUS_CODE" || true)"
posted=0
for p in "${problems[@]}"; do
  if grep -qF -- "$p" <<<"$current"; then continue; fi
  jq -n --arg e "$p" '{error: $e}' | curl -sS -f -m 20 -X POST -H "X-Token: $WEBHOOK_TOKEN" \
    -H "Content-Type: application/json" -d @- "$WEBHOOK_URL" >/dev/null && posted=$((posted + 1)) \
    || echo "could not post: $p" >&2
done
printf '%s\n' "${problems[@]:-}" | sed '/^$/d; s/^/problem: /'
echo "health-watch: ${#problems[@]} problem(s), $posted newly posted"
