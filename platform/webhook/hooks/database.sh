#!/bin/bash

# GET  /database?code=<STATUS_CODE> -> 200 only if both:
#        1. right now, atlas-mariadb (the shared MariaDB) accepts a connection and greets as MariaDB (live check);
#        2. health-watch's last real login + query (as the login-only user `health`, every 15 minutes) worked and is under 45 minutes old.
#      else 500 with one short line. Without the right code: a bare 500.
# POST /database (header X-Token) with {"ok": true|false, "detail": "..."}: health-watch's report.

STATE=/locks/status_database.json
MAX_AGE=2700
DB_HOST=atlas-mariadb.atlas
DB_PORT=3306

METHOD=$(echo "$hook_method" | tr '[:lower:]' '[:upper:]')

case "$METHOD" in
  POST)
    if [ -z "${WEBHOOK_TOKEN:-}" ] || [ "${x_token:-}" != "$WEBHOOK_TOKEN" ]; then
      echo "forbidden"
      exit 1
    fi
    echo "$1" | jq -c --arg t "$(date -u +%s)" '{ok: (.ok == true), detail: ((.detail // "") | tostring | .[0:200]), at: ($t | tonumber)}' \
      > "$STATE.tmp" && mv "$STATE.tmp" "$STATE" || exit 1
    exit 0
    ;;
  GET)
    # Only callers with ?code=<STATUS_CODE> learn anything: everyone else gets a bare 500.
    [ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1

    # 1. Live: open the port and read MariaDB's greeting (it starts with its version, e.g. 13.0.2-MariaDB).
    greeting=$(timeout 5 bash -c "exec 3<>/dev/tcp/$DB_HOST/$DB_PORT && dd bs=200 count=1 <&3 2>/dev/null" | tr -d '\000')
    version=$(echo "$greeting" | grep -a -o '[0-9][0-9.]*-MariaDB' | head -n 1)
    if [ -z "$version" ]; then
      echo "database not answering right now"
      exit 1
    fi

    # 2. The last real login and query
    if [ ! -f "$STATE" ]; then
      echo "answering ($version), but no login check reported yet"
      exit 1
    fi
    age=$(( $(date -u +%s) - $(jq -r .at "$STATE") ))
    if [ "$age" -gt "$MAX_AGE" ]; then
      echo "answering ($version), but no login check for $(( age / 60 )) minutes (health-watch not running?)"
      exit 1
    fi
    if [ "$(jq -r .ok "$STATE")" = true ]; then
      echo "ok: $version up, $(jq -r .detail "$STATE")"
      exit 0
    fi
    echo "answering ($version), but $(jq -r .detail "$STATE")"
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
