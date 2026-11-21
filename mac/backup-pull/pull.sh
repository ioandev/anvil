#!/bin/bash
# Local copy of the server's databases, on this machine or any other (Linux or macOS), ENCRYPTED. Settings in .env
# next to this file (see .env.example and README.md). Two sources, chosen with SOURCE= in .env (or the first argument):
#
#   bucket  the nightly off-site backups (every atlas database and the SQLite backups), fetched from the bucket with a key
#           that can only READ and LIST it. Safe on any machine. Needs PULL_S3_ACCESS_KEY/SECRET (HUMAN.md H24).
#             $DEST/daily/<date>/<source>/<file>.age     kept DAILY_KEEP_DAYS here (the bucket itself keeps 30)
#             $DEST/monthly/<YYYY-MM>/<source>/<file>.age   kept forever
#   live    a fresh dump of every atlas database right now, over SSH to the server, as the read-only atlas_backup user.
#           Needs the server's SSH key, which is root on the server: only on machines you'd trust with that.
#             $DEST/live/<UTC time>/<database>.sql.gz.age   kept LIVE_KEEP_DAYS
#   both    live, then bucket
#
# Encryption: every file is encrypted with age to AGE_RECIPIENT (a PUBLIC key) while it streams in, so no plaintext
# copy is ever written here, and this machine can't read its own copies: only the matching private key can
# (age -d -i <key file>). Every database dump is checked while it streams (gzip intact, ends with "Dump completed")
# and a bad one is never kept. Started with --daily (the schedule does that every hour) it runs at most once a day,
# so a PC that was off catches up when it's back on. A failure posts one line to the server's error list
# (STATUS_URL/error_arduino) when WEBHOOK_TOKEN and STATUS_URL are set. Log: pull.log next to this file. Restore: README.md.
set -Eeuo pipefail
umask 077
cd "$(dirname "$0")"
HERE="$(pwd)"
DAILY=0; [ "${1:-}" = "--daily" ] && { DAILY=1; shift; }
exec >>"$HERE/pull.log" 2>&1
set -a; . ./.env; set +a
export PATH="$PATH:$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/Applications/Docker.app/Contents/Resources/bin"
SOURCE="${1:-${SOURCE:-bucket}}"
DEST="${DEST:-$HOME/${ANVIL_NAME:-anvil}-backups}"
DAILY_KEEP_DAYS="${DAILY_KEEP_DAYS:-90}"
LIVE_KEEP_DAYS="${LIVE_KEEP_DAYS:-30}"
[ "$DAILY_KEEP_DAYS" -ge 31 ] || DAILY_KEEP_DAYS=31   # below the bucket's 30 days, deleted dailies would be fetched again
mkdir -p "$DEST"
now() { date -u '+%F %T'; }
epoch_of_day() { date -u -j -f %F "$1" +%s 2>/dev/null || date -u -d "$1" +%s; }

if [ "$DAILY" = 1 ] && [ "$(cut -c1-10 "$DEST/.last-pull-ok" 2>/dev/null)" = "$(date -u +%F)" ]; then
  exit 0   # already done today
fi

fail() {
  echo "$(now) FAILED ($SOURCE) at line $1" >&2
  [ -z "${WEBHOOK_TOKEN:-}" ] || [ -z "${STATUS_URL:-}" ] || curl -sS -m 20 -X POST -H "X-Token: $WEBHOOK_TOKEN" -H "Content-Type: application/json" \
    -d "{\"error\":\"backup pull ($SOURCE) failed on $(hostname -s) $(date -u +%F)\"}" "$STATUS_URL/error_arduino" >/dev/null || true
}
trap 'fail $LINENO' ERR

: "${AGE_RECIPIENT:?AGE_RECIPIENT missing in .env (the age public key, age1...)}"
command -v age >/dev/null || { echo "age not installed (Linux: package age; macOS: brew install age)"; false; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# store <out file> [dump]: encrypts stdin to <out file>.age, atomically. With "dump", the stream must be a complete
# gzipped mariadb-dump (checked as it passes, nothing written in plaintext), or nothing is kept.
store() {
  local out="$1" kind="${2:-}" fifo="$TMP/check" ok="$TMP/check.ok" pid=""
  trap - ERR   # runs in a pipeline's subshell: the caller reports a failure, once
  mkdir -p "$(dirname "$out")"
  rm -f "$fifo" "$ok"
  if [ "$kind" = dump ]; then
    mkfifo "$fifo"
    # The checker always reads to the end (cat drains whatever gzip leaves), so tee is never cut off.
    ( cat "$fifo" | { if gzip -dc 2>/dev/null | tail -n 1 | grep -q "Dump completed"; then : > "$ok"; fi; cat >/dev/null; } ) &
    pid=$!
    tee "$fifo" | age -r "$AGE_RECIPIENT" -o "$out.age.part"
    wait "$pid" || true
    [ -e "$ok" ] || { rm -f "$out.age.part"; echo "rejected (incomplete dump): $out"; return 1; }
  else
    age -r "$AGE_RECIPIENT" -o "$out.age.part"
  fi
  mv "$out.age.part" "$out.age"
}

prune() {  # prune <dir> <name pattern> <days> <how to get YYYY-MM-DD from the folder name>
  find "$1" -mindepth 1 -maxdepth 1 -type d -name "$2" 2>/dev/null | while read -r d; do
    local day; day="$(basename "$d" | sed -E "$4")"
    if [ $(( ( $(date -u +%s) - $(epoch_of_day "$day") ) / 86400 )) -gt "$3" ]; then rm -rf "$d"; fi
  done
}

pull_live() {
  : "${SERVER:?SERVER missing in .env}" "${SSH_KEY:?SSH_KEY missing in .env}" "${ATLAS_BACKUP_PASSWORD:?ATLAS_BACKUP_PASSWORD missing in .env}"
  local ssh_=(ssh -i "${SSH_KEY/#\~/$HOME}" -p "${SSH_PORT:-52699}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new
              -o ConnectTimeout=20 -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-backup-pull-%r@%h:%p"
              -o ControlPersist=60 "core@$SERVER")
  # Runs inside the atlas pod; the password arrives on stdin, never on a command line.
  local pod_script b64
  pod_script='read -r p; export MYSQL_PWD="$p"
case "$1" in
  list) exec mariadb -h127.0.0.1 -u atlas_backup -N -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('"'"'mysql'"'"','"'"'information_schema'"'"','"'"'performance_schema'"'"','"'"'sys'"'"')" ;;
  dump) mariadb-dump -h127.0.0.1 -u atlas_backup --single-transaction --routines --triggers --events --hex-blob \
          --default-character-set=utf8mb4 --no-tablespaces --databases "$2" | gzip -6 ;;
esac'
  b64="$(printf '%s' "$pod_script" | base64 | tr -d '\n')"
  pod() { printf '%s\n' "$ATLAS_BACKUP_PASSWORD" | "${ssh_[@]}" \
    "sudo /opt/bin/kubectl -n atlas exec -i atlas-mariadb-0 -- sh -c 'eval \"\$(echo $b64 | base64 -d)\"' sh $*"; }

  local stamp dir dbs db n=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"; dir="$DEST/live/$stamp"
  mkdir -p "$dir.part"
  dbs="$(pod list)"
  [ -n "$dbs" ]
  for db in $dbs; do
    case "$db" in *[!a-zA-Z0-9_]*) echo "skipping odd database name: $db"; continue ;; esac
    pod dump "$db" | store "$dir.part/$db.sql.gz" dump
    n=$((n + 1))
  done
  mv "$dir.part" "$dir"
  echo "$(now) live: $n databases dumped, checked and encrypted into $dir ($(du -sh "$dir" | cut -f1))"
  prune "$DEST/live" '20*Z' "$LIVE_KEEP_DAYS" 's/^(....)(..)(..).*/\1-\2-\3/'
  find "$DEST/live" -mindepth 1 -maxdepth 1 -type d -name '*.part' -mmin +120 -exec rm -rf {} + 2>/dev/null || true
}

pull_bucket() {
  : "${BACKUP_BUCKET:?BACKUP_BUCKET missing in .env}" "${PULL_S3_ACCESS_KEY:?PULL_S3_ACCESS_KEY missing in .env (HUMAN.md H24)}" "${PULL_S3_SECRET_KEY:?PULL_S3_SECRET_KEY missing in .env}"
  export RCLONE_CONFIG_BK_TYPE=s3 RCLONE_CONFIG_BK_PROVIDER=Scaleway RCLONE_CONFIG_BK_REGION=fr-par \
         RCLONE_CONFIG_BK_ENDPOINT=s3.fr-par.scw.cloud RCLONE_CONFIG_BK_ACCESS_KEY_ID="$PULL_S3_ACCESS_KEY" \
         RCLONE_CONFIG_BK_SECRET_ACCESS_KEY="$PULL_S3_SECRET_KEY"
  local rt=""; command -v rclone >/dev/null || rt="$(command -v docker || command -v podman || true)"
  command -v rclone >/dev/null || [ -n "$rt" ] || { echo "bucket mode needs rclone, docker or podman"; return 1; }
  rcl() {
    if [ -z "$rt" ]; then rclone --config /dev/null --s3-no-check-bucket --retries 3 "$@"
    else "$rt" run --rm -i -e RCLONE_CONFIG_BK_TYPE -e RCLONE_CONFIG_BK_PROVIDER -e RCLONE_CONFIG_BK_REGION \
           -e RCLONE_CONFIG_BK_ENDPOINT -e RCLONE_CONFIG_BK_ACCESS_KEY_ID -e RCLONE_CONFIG_BK_SECRET_ACCESS_KEY \
           docker.io/rclone/rclone:1.75.1 --config /dev/null --s3-no-check-bucket --retries 3 "$@"; fi
  }
  local list f n=0 newest age
  list="$TMP/list"
  rcl lsf -R --files-only "bk:$BACKUP_BUCKET" > "$list"
  [ -s "$list" ]
  # Only what this machine doesn't have yet; each file streams straight into age.
  while IFS= read -r f; do
    case "$f" in daily/*|monthly/*) ;; *) continue ;; esac
    case "$f" in *..*|/*) echo "skipping odd path: $f"; continue ;; esac
    [ -e "$DEST/$f.age" ] && continue
    if [ "$(dirname "$f" | cut -d/ -f1)" = daily ]; then   # older than we keep: it was pruned here on purpose
      local day; day="$(echo "$f" | cut -d/ -f2)"
      [ $(( ( $(date -u +%s) - $(epoch_of_day "$day") ) / 86400 )) -gt "$DAILY_KEEP_DAYS" ] && continue
    fi
    case "$f" in */mariadb/*.sql.gz) rcl cat "bk:$BACKUP_BUCKET/$f" < /dev/null | store "$DEST/$f" dump ;;
                 *) rcl cat "bk:$BACKUP_BUCKET/$f" < /dev/null | store "$DEST/$f" ;; esac
    n=$((n + 1))
  done < "$list"
  # The bucket's newest daily must be recent, or the nightly backups themselves have stopped.
  newest="$(grep '^daily/' "$list" | cut -d/ -f2 | sort | tail -n 1)"
  [ -n "$newest" ]
  age=$(( ( $(date -u +%s) - $(epoch_of_day "$newest") ) / 86400 ))
  [ "$age" -le 2 ] || { echo "the bucket's newest daily backup is $newest ($age days old)"; false; }
  prune "$DEST/daily" '20??-??-??' "$DAILY_KEEP_DAYS" 's/x/x/'
  echo "$(now) bucket: $n new files fetched, checked and encrypted; newest daily $newest"
}

echo "$(now) start ($SOURCE) into $DEST"
case "$SOURCE" in
  live) pull_live ;;
  bucket) pull_bucket ;;
  both) pull_live; pull_bucket ;;
  *) echo "SOURCE must be live, bucket or both"; false ;;
esac
date -u '+%FT%TZ' > "$DEST/.last-pull-ok"
echo "$(now) ok ($SOURCE): $(du -sh "$DEST" | cut -f1) on disk"
