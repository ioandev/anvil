#!/bin/bash

# GET /space?code=<STATUS_CODE> -> 200 while the server's disk (/, the node's root disk: images, volumes, databases) has at least
# MIN_SPACE_GB free, 500 below that. The body says how much is free.
MIN_SPACE_GB=10

# Only callers with ?code=<STATUS_CODE> learn anything: everyone else gets a bare 500.
[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1

AVAILABLE_SPACE_KB=$(df -k / | awk 'NR==2 {print $4}')
AVAILABLE_SPACE_GB=$(echo "scale=1; $AVAILABLE_SPACE_KB/1048576" | bc)

if (( $(echo "$AVAILABLE_SPACE_GB < $MIN_SPACE_GB" | bc -l) )); then
    echo "low: ${AVAILABLE_SPACE_GB} GB free (minimum ${MIN_SPACE_GB} GB)"
    exit 1
else
    echo "ok: ${AVAILABLE_SPACE_GB} GB free"
    exit 0
fi
