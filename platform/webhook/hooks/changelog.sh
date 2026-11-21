#!/bin/bash

# GET /changelog?code=<STATUS_CODE>&days=N: the post-mortems (what the autopilot did and what the owner did), newest
# day first. days defaults to 14; days=0 = all. &format=files prefixes each file with "=== <date>.md ===" (used by the
# auto-commit to mirror them into git, postmortems/). Without the right code: a bare 500.

[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1
DIR=/locks/postmortems
n=${days:-14}; case "$n" in ''|*[!0-9]*) n=14 ;; esac
[ -d "$DIR" ] || { echo "(no post-mortems yet)"; exit 0; }
files=$(ls -1 "$DIR"/*.md 2>/dev/null | sort -r)
[ "$n" -gt 0 ] && files=$(echo "$files" | head -n "$n")
[ -n "$files" ] || { echo "(no post-mortems yet)"; exit 0; }
for f in $files; do
  [ "${format:-}" = files ] && echo "=== $(basename "$f") ==="
  cat "$f"; echo
done
