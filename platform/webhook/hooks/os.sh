#!/bin/bash

# GET /os?code=<STATUS_CODE> -> 200 while every node runs the newest Flatcar release of its channel, else 500 with what's
# available and how to update (scripts/os-update). Automatic OS updates are off on purpose, so this is what tells the
# owner a security release is out. NOT part of /overall: a pending OS update never phones anyone.
#   - the node's version: kube-state-metrics' kube_node_info{os_image} via Prometheus;
#   - the newest release: the channel's version.txt (FLATCAR_CHANNEL, default stable), cached for 6 hours in /locks.
#     Fails closed: if the feed can't be read and the cached answer is over 3 days old, 500 ("can't check").
# Without the right code: a bare 500.
[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1

PROM=http://alerting-prometheus.alerting:9090
CHANNEL=${FLATCAR_CHANNEL:-stable}
CACHE=/locks/flatcar_latest.json
now=$(date -u +%s)

# The newest release (cached)
age=$(( now - $(jq -r '.at // 0' "$CACHE" 2>/dev/null || echo 0) ))
if [ "$age" -gt 21600 ]; then
  # -L: the feed address redirects
  feed=$(curl -sfL -m 10 "https://$CHANNEL.release.flatcar-linux.net/amd64-usr/current/version.txt") || feed=""
  v=$(echo "$feed" | sed -n 's/^FLATCAR_VERSION=//p'); built=$(echo "$feed" | sed -n 's/^FLATCAR_BUILD_ID="\{0,1\}\([0-9-]\{10\}\).*/\1/p')
  if [ -n "$v" ]; then
    jq -n --arg v "$v" --arg b "$built" --argjson at "$now" '{version: $v, built: $b, at: $at}' > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
    age=0
  elif [ ! -s "$CACHE" ]; then
    echo "can't check: the $CHANNEL release feed didn't answer (and there's no earlier answer)"; exit 1
  elif [ "$age" -gt 259200 ]; then
    echo "can't check: the $CHANNEL release feed hasn't answered for over 3 days"; exit 1
  fi
fi
latest=$(jq -r '.version' "$CACHE" 2>/dev/null); built=$(jq -r '.built // ""' "$CACHE" 2>/dev/null)
[ -n "$latest" ] && [ "$latest" != null ] || { echo "can't check: no release information yet"; exit 1; }

# Every node's version
nodes=$(curl -sf -m 8 --get "$PROM/api/v1/query" --data-urlencode 'query=kube_node_info' \
  | jq -r '.data.result[] | "\(.metric.node) \(.metric.os_image | capture("(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)").v) \(.metric.kernel_version)"') \
  || { echo "can't check: Prometheus didn't answer"; exit 1; }
[ -n "$nodes" ] || { echo "can't check: no node information in Prometheus"; exit 1; }

behind=""; ok=""
while read -r node v kernel; do
  if [ "$v" != "$latest" ] && [ "$(printf '%s\n%s\n' "$v" "$latest" | sort -V | tail -1)" = "$latest" ]; then
    behind+="$node runs Flatcar $v, $latest is out (${built:-$CHANNEL}); update: scripts/os-update --yes. "
  else
    ok+="$node: Flatcar $v ($CHANNEL, newest), kernel $kernel. "
  fi
done <<< "$nodes"
if [ -n "$behind" ]; then echo "${behind% }"; exit 1; fi
echo "${ok% }"
