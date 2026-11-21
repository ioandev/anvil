---
name: 50-demo-app
description: Sixth anvil bootstrap step. Deploys the demo app (anvil-demo guestbook + worker), points demo., status. and www. at the server through Cloudflare, and verifies them from outside. Use after 40-platform.
---

# 50-demo-app: something to show

1. `scripts/node.sh deploy anvil-demo` (its Secret `anvil-demo` with ADMIN_TOKEN and `atlas-db` come from
   make-secrets; its database and users from atlas-users).
2. Before DNS: through Traefik on the box with the origin-pull cert:
   `scripts/node.sh curl demo.$ANVIL_DOMAIN /` → 200, `/readyz` → 200.
3. **Cutover** (only once 20-cloudflare saw the edge certificate active):
   `python3 -I scripts/cutover.py $ANVIL_SERVER_IP $(python3 -I scripts/sites.py hosts anvil-demo) status.$ANVIL_DOMAIN`.
4. Verify from outside through a Cloudflare IP (this machine's resolver may be stale):
   `curl -s -o /dev/null -w '%{http_code}' --resolve demo.$ANVIL_DOMAIN:443:<a Cloudflare IP> https://demo.$ANVIL_DOMAIN/`
   → 200. Then the real URLs: `https://demo.$ANVIL_DOMAIN/`, `https://status.$ANVIL_DOMAIN/overall?code=…` → 200.
5. Post one guestbook entry in a browser; the worker approves it within seconds.
6. **The cluster's own probes may stay red for up to an hour after the cutover** although the site works from outside:
   the server's resolvers (Scaleway's, which CoreDNS forwards to) cache the "no such name" they answered before the
   records existed (seen on the first real install: NXDOMAIN from 169.254.169.254 and Scaleway's 51.159.69.x while
   1.1.1.1 and Tailscale's 100.100.100.100 already had the address). Check from a pod
   (`nslookup demo.$ANVIL_DOMAIN <resolver>` per resolver) and wait; keep the alerts silenced meanwhile, or the
   `SiteDown` / `ServerHealthRed` calls start. Creating the DNS records early (before deploying) avoids most of it.

Done when `/cluster?code=…` is 200 (every probe green, every workload ready).
