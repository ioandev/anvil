#!/bin/bash

# POST /postmortem (header X-Token) with {"author": "autopilot|owner|claude", "text": "<markdown>", "at": "<ISO, optional>"}:
# appends "## HH:MM (UK) · <author>" + text to /locks/postmortems/<date>.md, where <date> is the UK date of "at"
# (default now) minus one day if it's before 08:00 UK time. Read them with GET /changelog. (INTERFACES.md in github.com/ioandev/autopilot)

DIR=/locks/postmortems
METHOD=$(echo "$hook_method" | tr '[:lower:]' '[:upper:]')
[ "$METHOD" = POST ] || exit 1
if [ -z "${WEBHOOK_TOKEN:-}" ] || [ "${x_token:-}" != "$WEBHOOK_TOKEN" ]; then echo "forbidden"; exit 1; fi

mkdir -p "$DIR" || exit 1
# webhookd passes the body only with Content-Type: application/json (or text/*); without it $1 is empty.
[ -n "$1" ] || { echo '{"ok":false,"error":"empty body: send Content-Type: application/json"}'; exit 1; }
out=$(echo "$1" | jq -r --arg now "$(date -u +%s)" -L "$(dirname "$0")" 'include "_ukdate";
  (if (.at // "") != "" then (.at | sub("\\.[0-9]+"; "") | sub("Z$"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime) else ($now | tonumber) end) as $t
  | [($t | pm_date), "## \($t | uk_hhmm) · \(.author // "unknown" | tostring | .[0:30])\n\n\(.text // "" | tostring | .[0:20000])\n"] | @json') || { echo "bad body"; exit 1; }
day=$(echo "$out" | jq -r '.[0]'); entry=$(echo "$out" | jq -r '.[1]')
case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) echo "bad date"; exit 1 ;; esac
f="$DIR/$day.md"
[ -f "$f" ] || printf '# %s\n\n' "$day" > "$f"
printf '%s\n' "$entry" >> "$f" || exit 1
echo "added to $day"
