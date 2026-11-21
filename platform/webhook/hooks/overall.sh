#!/bin/bash

# GET /overall?code=<STATUS_CODE> -> 200 only if /space, /database, /backups and /cluster are all 200, else 500. Each check's one-line result is
# listed, problems first. (/error_arduino is separate: it's a latch you clear by hand, this is the live state.)

# Only callers with ?code=<STATUS_CODE> learn anything: everyone else gets a bare 500.
[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1

DIR="$(dirname "$0")"
ok=()
bad=()
for check in space database backups cluster; do
  out="$(hook_method=GET "$DIR/$check.sh" 2>&1)"
  rc=$?   # not "code": that's the ?code= secret, which the checks below need too
  out="$(echo "$out" | head -n 1)"
  if [ "$rc" -eq 0 ]; then
    ok+=("$check: $out")
  else
    bad+=("$check: $out")
  fi
done

printf '%s\n' "${bad[@]}" "${ok[@]}" | sed '/^$/d'
# Remember the verdict (no details) for /up, the code-free status for outside monitors
printf '{"ok": %s, "at": %s}\n' "$([ "${#bad[@]}" -eq 0 ] && echo true || echo false)" "$(date -u +%s)" > /locks/status_up.json.tmp \
  && mv /locks/status_up.json.tmp /locks/status_up.json
[ "${#bad[@]}" -eq 0 ]
