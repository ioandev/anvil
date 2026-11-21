#!/bin/sh
# GET /cgi-bin/runs: every autopilot run's summary (the .json the Mac uploads next to each transcript), newest first,
# as one JSON array: [{"id": "<UTC time>", "meta": {...}, "size": <transcript bytes>}, ...]. Read-only.
echo "Content-Type: application/json; charset=utf-8"
echo "Cache-Control: no-store"
echo
D=/locks/autopilot/runs
printf '['
first=1
for j in $(ls -1 "$D"/*.json 2>/dev/null | sort -r); do
  [ -s "$j" ] || continue
  id=$(basename "$j" .json)
  case "$id" in *[!0-9A-Za-z_:.-]*) continue ;; esac
  size=0; [ -f "$D/$id.md" ] && size=$(wc -c < "$D/$id.md")
  [ $first = 1 ] || printf ','
  first=0
  printf '{"id":"%s","size":%d,"meta":' "$id" "$size"
  cat "$j"
  printf '}'
done
printf ']\n'
