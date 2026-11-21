#!/bin/bash
# Clears the arduino error lock set by hooks/error_arduino.sh (POST /error_arduino).
# Run from the repo root: platform/webhook/clear-error-arduino.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
scripts/node.sh kubectl -n webhook exec deploy/webhook -- sh -c '
  f=/locks/error_arduino.lock
  if [ ! -f "$f" ]; then echo "No lock set"; exit 0; fi
  echo "Logged errors:"; cat "$f"; rm -f "$f"; echo "Lock cleared"'
