#!/bin/bash
# Nightly OpenBao snapshot (launchd com.anvil.${ANVIL_NAME}-openbao-backup, 06:30). A Raft snapshot is still encrypted by the seal:
# restoring it needs seal.key. Keeps 30 days in ~/${ANVIL_NAME}-openbao-backups, and copies each one off the Mac to the private
# bucket ${ANVIL_OPENBAO_BUCKET} (fr-par, 90-day expiry) with the WRITE-ONLY backup key in ~/${ANVIL_NAME}-openbao/offsite.env (it can't read, list or
# delete, so a compromised Mac can't erase the off-site copies).
set -euo pipefail
export PATH="$PATH:/Applications/Docker.app/Contents/Resources/bin:/usr/local/bin"
DIR="$HOME/${ANVIL_NAME}-openbao-backups"; mkdir -p "$DIR"; chmod 700 "$DIR"
TOKEN=$(cat "$HOME/${ANVIL_NAME}-openbao/backup.token")
F="$DIR/openbao-$(date -u +%Y%m%d-%H%M).snap"
docker exec -e BAO_TOKEN="$TOKEN" openbao bao operator raft snapshot save /tmp/s.snap
docker cp openbao:/tmp/s.snap "$F" && docker exec openbao rm -f /tmp/s.snap
chmod 600 "$F"
find "$DIR" -name 'openbao-*.snap' -mtime +30 -delete
echo "$(date -u +%FT%TZ) saved $F ($(du -h "$F" | cut -f1))"

# Off-site copy (signed PUT; the key can only write)
. "$HOME/${ANVIL_NAME}-openbao/offsite.env"
code=$(curl -s -o /dev/null -w '%{http_code}' --aws-sigv4 "aws:amz:fr-par:s3" --user "$OFFSITE_ACCESS_KEY:$OFFSITE_SECRET_KEY" \
  -T "$F" "https://$OFFSITE_BUCKET.s3.fr-par.scw.cloud/$(basename "$F")")
[ "$code" = 200 ] && echo "uploaded to $OFFSITE_BUCKET" || { echo "UPLOAD FAILED: HTTP $code"; exit 1; }
