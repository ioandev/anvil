#!/bin/bash
# Nightly off-site backup for ${PLATFORM_NAME:-anvil}. Writes files to /work, uploads them (signed PUTs) to the backup bucket under
#   daily/<YYYY-MM-DD>/<source>/   (the bucket expires these after 30 days)
#   monthly/<YYYY-MM>/<source>/    (on the 1st; expire after 365 days)
# and emails ALERT_TO if anything fails. The key can write but not delete or list, so nothing on the server
# can remove old backups.
#
#   server-backup mariadb                 every database in atlas, one gzipped dump each (as atlas_backup)
#   server-backup sqlite <name> <dir>     every *.db in <dir> via SQLite's online .backup, plus its other files
#   server-backup check <ns/cronjob>...   morning watchdog: emails if any of these hasn't succeeded in 26 h (also
#                                         catches jobs that never started, which can't email themselves), and
#                                         sends a weekly "all OK" on Mondays so silence itself is noticeable
#
# Env: BACKUP_BUCKET, BACKUP_S3_ACCESS_KEY, BACKUP_S3_SECRET_KEY, ALERT_TO, ALERT_FROM, TEM_PROJECT_ID, WEBHOOK_URL, WEBHOOK_TOKEN;
#      for mariadb also DB_HOST, DB_USER, MYSQL_PWD.
set -Eeuo pipefail

mode="${1:?mode: mariadb | sqlite | check}"
source_name="$mode"; [ "$mode" = sqlite ] && source_name="${2:?name}"
# BACKUP_SOURCE: a second MariaDB's backup gets its own folder (a database moved off atlas by scripts/move-db uploads to
# mariadb-<ns>, never over atlas's files of the same name).
source_name="${BACKUP_SOURCE:-$source_name}"
day="$(date -u +%F)"
work="/work/$source_name"
mkdir -p "$work"

alert() {  # best effort: a failed alert must not hide the real error
  latch "backup $source_name failed $day"
  send "${PLATFORM_NAME:-anvil} backup FAILED: $source_name ($day)" \
    "The nightly backup of '$source_name' failed on $(date -u '+%F %T') UTC at line $1 of server-backup. Check its Job's logs (kubectl -n <ns> get jobs; kubectl -n <ns> logs job/<name>)." \
    || echo "alert email failed too" >&2
}
trap 'alert $LINENO' ERR

latch() {  # latch <short line>: the error latch the owner polls (webhookd /error_arduino); best effort
  [ -n "${WEBHOOK_URL:-}" ] || return 0
  jq -n --arg e "$1" '{error: $e}' | curl -sS -m 20 -X POST -H "X-Token: ${WEBHOOK_TOKEN:-}" \
    -H "Content-Type: application/json" -d @- "$WEBHOOK_URL" >/dev/null || true
}

send() {  # send <subject> <text>
  jq -n --arg p "$TEM_PROJECT_ID" --arg f "$ALERT_FROM" --arg t "$ALERT_TO" --arg s "$1" --arg b "$2" \
    '{project_id:$p, from:{email:$f, name:"${PLATFORM_NAME:-anvil} backups"}, to:[{email:$t}], subject:$s, text:$b}' |
  curl -sS -f -m 30 -X POST "https://api.scaleway.com/transactional-email/v1alpha1/regions/${BACKUP_REGION:-fr-par}/emails" \
    -H "X-Auth-Token: $BACKUP_S3_SECRET_KEY" -H "Content-Type: application/json" -d @- >/dev/null
}

if [ "$mode" = check ]; then
  shift
  api=https://kubernetes.default.svc; token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
  ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  now=$(date -u +%s); problems=""; report=""
  items=("$@")
  if [ ${#items[@]} -eq 0 ]; then   # no list: every CronJob labelled app.kubernetes.io/component=backup
    mapfile -t items < <(curl -sS -f -m 20 --cacert "$ca" -H "Authorization: Bearer $token" \
      "$api/apis/batch/v1/cronjobs?labelSelector=app.kubernetes.io%2Fcomponent%3Dbackup" |
      jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"') || items=()
    [ ${#items[@]} -gt 0 ] || { problems+="  (no backup CronJobs found, or they can't be listed)"$'\n'; }
  fi
  for item in "${items[@]}"; do
    ns="${item%%/*}"; cj="${item#*/}"
    last="$(curl -sS -f -m 20 --cacert "$ca" -H "Authorization: Bearer $token" \
      "$api/apis/batch/v1/namespaces/$ns/cronjobs/$cj" | jq -r '.status.lastSuccessfulTime // "never"')" || last=""
    # Fail closed: a CronJob we can't read (missing, no permission, API down) counts as not backed up. (An empty value
    # used to reach `date -d ""`, which is today's midnight: it looked fresh.)
    if [ -z "$last" ]; then last="unreadable"; age=999999
    elif [ "$last" = never ]; then age=999999; else age=$(( (now - $(date -u -d "$last" +%s)) / 3600 )); fi
    report+="  $ns/$cj: last success $last"$'\n'
    [ "$age" -le 26 ] || problems+="  $ns/$cj: last success $last ($age h ago)"$'\n'
  done
  printf '%s' "$report"
  if [ -n "$problems" ]; then
    while IFS= read -r line; do [ -n "$line" ] && latch "backup not running: $(echo "$line" | awk '{print $1}')"; done <<<"$problems"
    send "${PLATFORM_NAME:-anvil} backups: NOT RUNNING ($(date -u +%F))" "These backups haven't succeeded in the last 26 hours (a job that never started can't send its own alert):"$'\n'"$problems"$'\n'"Check: kubectl get cronjobs,jobs -n <ns>; kubectl describe job ..."
    echo "problems found, alert sent"; exit 1
  elif [ "$(date -u +%u)" = 1 ]; then
    send "${PLATFORM_NAME:-anvil} backups OK ($(date -u +%F))" "Weekly check: every nightly backup succeeded in the last 26 hours."$'\n'"$report"$'\n'"If this Monday email ever stops arriving, the check itself isn't running: look at atlas/backup-watch."
    echo "weekly OK sent"
  fi
  exit 0
fi

case "$mode" in
  mariadb)
    dbs="$(mariadb -h "$DB_HOST" -u "$DB_USER" -N -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys')")"
    [ -n "$dbs" ]
    for db in $dbs; do
      mariadb-dump -h "$DB_HOST" -u "$DB_USER" --single-transaction --routines --triggers --events --hex-blob \
        --default-character-set=utf8mb4 --no-tablespaces --databases "$db" | gzip -9 > "$work/$db.sql.gz"
      # A cut-off dump has no completion marker: refuse to upload it as if it were good.
      zcat "$work/$db.sql.gz" | tail -n 1 | grep -q "Dump completed"
    done
    ;;
  sqlite)
    src="${3:?dir}"
    found=0
    for f in "$src"/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      case "$base" in
        *.db) sqlite3 "$f" ".backup '$work/$base'"; sqlite3 "$work/$base" "PRAGMA integrity_check" | grep -qx ok
              gzip -9 "$work/$base"; found=1 ;;
        *.db-wal|*.db-shm|*.db-journal|.keep) ;;   # part of the live database; .backup already has it
        *) gzip -9c "$f" > "$work/$base.gz" ;;
      esac
    done
    [ "$found" = 1 ]
    ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac

# Plain signed PUTs (curl --aws-sigv4): the key may only write objects, so no listing, HEAD or bucket checks.
up() {  # up <prefix>: every file in $work to <prefix>/<source>/<file>
  local f
  for f in "$work"/*; do
    [ -f "$f" ] || continue
    curl -sS -f -m 300 --retry 3 --aws-sigv4 "aws:amz:${BACKUP_REGION:-fr-par}:s3" --user "$BACKUP_S3_ACCESS_KEY:$BACKUP_S3_SECRET_KEY" \
      -H "x-amz-acl: private" -T "$f" "https://$BACKUP_BUCKET.s3.${BACKUP_REGION:-fr-par}.scw.cloud/$1/$source_name/$(basename "$f")"
  done
}
up "daily/$day"
[ "$(date -u +%d)" = 01 ] && up "monthly/$(date -u +%Y-%m)"
ls -la "$work"
echo "backup ok: $source_name -> $BACKUP_BUCKET/daily/$day/$source_name"
