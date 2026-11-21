#!/usr/bin/env bash
# Downloads the Flatcar stable Scaleway image (~500MB) for terraform to upload.
set -euo pipefail
cd "$(dirname "$0")/.."

URL="${FLATCAR_IMAGE_URL:-https://stable.release.flatcar-linux.net/amd64-usr/current/flatcar_production_scaleway_image.qcow2}"
DEST="${1:-infra/downloads/flatcar_production_scaleway_image.qcow2}"

# After `make cleanup` the image pipeline is disabled — no point downloading.
if [[ -f infra/local.auto.tfvars ]] && grep -qE 'image_pipeline[[:space:]]*=[[:space:]]*false' infra/local.auto.tfvars; then
  echo "image pipeline disabled (infra/local.auto.tfvars) — skipping download"
  exit 0
fi

if [[ -s "$DEST" && "${FORCE:-0}" != "1" ]]; then
  echo "already present: $DEST (FORCE=1 to re-download)"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
curl -fL --retry 3 -C - -o "$DEST" "$URL"
echo "downloaded: $DEST"
