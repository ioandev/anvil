#!/bin/bash

# GET /memory (no code: public, at the owner's request) -> 200 while the node has at least MIN_AVAILABLE_MB of memory
# available, 500 below that. The body gives the node's real figures (what `free -m` shows on the node: available
# memory, total, swap), read from /proc/meminfo, which in this pod is the node's own (not a container limit). It
# reveals nothing but these numbers. Unlike Dozzle's view, "available" counts everything: k3s itself, containerd,
# the disk cache that can be given back. Aim to keep about 1 GB available (CLAUDE.md).
MIN_AVAILABLE_MB=500

awk -v min="$MIN_AVAILABLE_MB" '
  /^MemTotal:/     { total = $2 }
  /^MemAvailable:/ { avail = $2 }
  /^SwapTotal:/    { stot  = $2 }
  /^SwapFree:/     { sfree = $2 }
  END {
    if (!total || avail == "") { print "unknown: could not read the memory figures"; exit 1 }
    t = int(total / 1024); a = int(avail / 1024); u = t - a
    st = int(stot / 1024); su = int((stot - sfree) / 1024)
    state = (a < min) ? "low" : "ok"
    printf "%s: %d MB available of %d MB (%d MB in use, %d%% available); swap %d MB used of %d MB", state, a, t, u, a * 100 / t, su, st
    if (state == "low") printf " (minimum %d MB)", min
    printf "\n"
    exit (state == "low") ? 1 : 0
  }' /proc/meminfo
