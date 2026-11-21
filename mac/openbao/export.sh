#!/bin/bash
# Export every secret under secret/ to stdout, one JSON object per secret ({path, secret: <bao kv get -format=json>}) (PLAINTEXT: pipe it somewhere safe, e.g. | age -r <key> > x.age).
# Needs a token that can read and list them: BAO_TOKEN=... ./export.sh > ...
set -euo pipefail
export PATH="$PATH:/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin"
: "${BAO_TOKEN:?set BAO_TOKEN}"
bao() { docker exec -i -e BAO_TOKEN="$BAO_TOKEN" openbao bao "$@"; }
walk() { local p="$1" k
  for k in $(bao kv list -format=json "secret/$p" 2>/dev/null | tr -d '[]",' ); do
    case "$k" in
      */) walk "$p$k" ;;
      *) printf '{"path": "%s", "secret": ' "$p$k"; bao kv get -format=json "secret/$p$k"; printf '}\n' ;;
    esac
  done; }
walk ""
