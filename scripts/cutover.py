#!/usr/bin/env python3
"""Point hostnames at the server through Cloudflare (or back at an old server).

  scripts/cutover.py <new-ip> host [host...]          -> A <new-ip>, proxied; AAAA removed
  scripts/cutover.py --rollback <old-ip> host [...]   -> A <old-ip>, DNS-only

The zones must already exist on Cloudflare (scripts/cloudflare-zones.py) and be
active. Each host's existing A/AAAA records (mirrored from Namecheap, pointing
at server-2) are replaced, so there is never a moment with no record and never
two A records round-robining between boxes. The AAAA goes because the server
has no IPv6 and a leftover AAAA would send v6 clients straight to server-2.

Env: CLOUDFLARE_API_TOKEN (from anvil.env). Hosts of a site: scripts/sites.py hosts <ns>.
"""
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I leaves the script's folder off sys.path
import anvil_env  # noqa: E402
anvil_env.export()  # credentials from anvil.env

TOKEN = os.environ["CLOUDFLARE_API_TOKEN"]


def cf(method, path, body=None):
    req = urllib.request.Request(
        "https://api.cloudflare.com/client/v4" + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            out = json.load(r)
    except urllib.error.HTTPError as e:
        out = json.load(e)
    # Stop on any error: printing "A ... proxied" after a rejected change once left a www host on its old CNAME.
    if not out.get("success"):
        sys.exit(f"Cloudflare {method} {path}: {out.get('errors')}")
    return out


args = sys.argv[1:]
rollback = args[:1] == ["--rollback"]
if rollback:
    args = args[1:]
if len(args) < 2:
    sys.exit(__doc__)
ip, hosts = args[0], args[1:]

zones = {z["name"]: z for z in cf("GET", "/zones?per_page=50")["result"]}
for host in hosts:
    zone = next((zones[n] for n in sorted(zones, key=len, reverse=True)
                 if host == n or host.endswith("." + n)), None)
    if zone is None:
        sys.exit(f"{host}: no Cloudflare zone")
    if zone["status"] != "active":
        print(f"warning: {zone['name']} is {zone['status']} — change takes effect once nameservers switch")
    zid = zone["id"]
    recs = cf("GET", f"/zones/{zid}/dns_records?name={host}&per_page=50")["result"]
    # A CNAME can't coexist with an A record (Cloudflare rejects the A): replace it, and say what it was so a rollback
    # can put it back (e.g. www -> parkingpage.namecheap.com on a freshly moved domain).
    for r in recs:
        if r["type"] == "CNAME":
            cf("DELETE", f"/zones/{zid}/dns_records/{r['id']}")
            print(f"{host}: removed CNAME {r['content']} (re-add by hand if rolling back)")
    a = [r for r in recs if r["type"] == "A"]
    want = {"type": "A", "name": host, "content": ip, "ttl": 1 if not rollback else 300,
            "proxied": not rollback}
    if a:
        cf("PUT", f"/zones/{zid}/dns_records/{a[0]['id']}", want)
        for extra in a[1:]:
            cf("DELETE", f"/zones/{zid}/dns_records/{extra['id']}")
    else:
        cf("POST", f"/zones/{zid}/dns_records", want)
    if not rollback:
        for r in recs:
            if r["type"] == "AAAA":
                cf("DELETE", f"/zones/{zid}/dns_records/{r['id']}")
                print(f"{host}: removed AAAA {r['content']} (re-add by hand if rolling back)")
    print(f"{host}: A {ip} {'proxied' if not rollback else 'DNS-only'}")
