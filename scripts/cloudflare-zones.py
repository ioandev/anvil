#!/usr/bin/env python3
"""Create the Cloudflare zones for the migrated domains and mirror their
current (Namecheap) DNS records into them, so switching nameservers changes
nothing by itself. Idempotent: existing zones/records are left alone.

Records are created DNS-only (grey cloud) and keep their current targets;
scripts/cutover.py later flips the hosts served by the server to proxied A records.
Every zone also gets Full (strict) SSL and Authenticated Origin Pulls with our
own client certificate (ensure_origin_pull).

Usage: scripts/cloudflare-zones.py   (CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID from anvil.env)
"""
import json
import pathlib
import os
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I leaves the script's folder off sys.path
import anvil_env  # noqa: E402
anvil_env.export()  # credentials from anvil.env
import sites  # noqa: E402

TOKEN = os.environ["CLOUDFLARE_API_TOKEN"]
ACCOUNT = os.environ["CLOUDFLARE_ACCOUNT_ID"]

# zone -> names (relative, "@" = apex) to look up and mirror: sites.yaml `zones: <zone>: records:`.
ZONES = sites.zone_records()
TYPES = ["A", "AAAA", "CNAME", "MX", "TXT", "CAA"]


def cf(method, path, body=None):
    req = urllib.request.Request(
        "https://api.cloudflare.com/client/v4" + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)


def doh(name, rtype):
    q = urllib.parse.urlencode({"name": name, "type": rtype})
    req = urllib.request.Request(f"https://dns.google/resolve?{q}")
    with urllib.request.urlopen(req) as r:
        d = json.load(r)
    # Answers for CNAME-chased lookups include the chain; keep only this name+type.
    want = {"A": 1, "AAAA": 28, "CNAME": 5, "MX": 15, "TXT": 16, "CAA": 257}[rtype]
    return [a for a in d.get("Answer", []) if a["type"] == want and a["name"].rstrip(".") == name]


def zone_id(name):
    r = cf("GET", f"/zones?name={name}&account.id={ACCOUNT}")
    if r["result"]:
        return r["result"][0]
    r = cf("POST", "/zones", {"name": name, "account": {"id": ACCOUNT}, "type": "full", "jump_start": False})
    if not r["success"]:
        # Free plan caps *pending* zones; the rest can be added once the
        # first ones are active (nameservers switched). Re-run then.
        print(f"{name}: zone create failed, skipping: {r['errors']}")
        return None
    return r["result"]


def record_body(fqdn, rtype, data, ttl):
    body = {"name": fqdn, "type": rtype, "ttl": max(ttl, 60), "proxied": False}
    if rtype == "MX":
        prio, target = data.split(None, 1)
        body.update(priority=int(prio), content=target.rstrip("."))
    elif rtype == "TXT":
        # DoH returns TXT as one or more quoted chunks; Cloudflare wants the quoted form.
        body["content"] = data if data.startswith('"') else f'"{data}"'
    elif rtype == "CAA":
        flags, tag, value = data.split(None, 2)
        body["data"] = {"flags": int(flags), "tag": tag, "value": value.strip('"')}
    else:
        body["content"] = data.rstrip(".")
    return body


# Authenticated Origin Pulls with OUR certificate (not Cloudflare's shared one,
# which every Cloudflare customer can present): Cloudflare shows this client
# cert on every proxied request, and Traefik (infra/manifests/origin-pull.yaml.tpl)
# rejects any TLS handshake without one signed by our CA. Files live outside
# git in AOP_DIR (generated once; see README).
AOP_DIR = pathlib.Path(os.environ.get("AOP_DIR", str(anvil_env.REPO / ".data/cloudflare-aop")))  # scripts/origin-pull-ca


def ensure_origin_pull(zid, zone):
    cert = (AOP_DIR / "client.crt").read_text().strip()
    have = cf("GET", f"/zones/{zid}/origin_tls_client_auth")["result"] or []
    if not any(c.get("certificate", "").strip() == cert and c.get("status") in ("active", "pending_deployment")
               for c in have):
        r = cf("POST", f"/zones/{zid}/origin_tls_client_auth",
               {"certificate": cert, "private_key": (AOP_DIR / "client.key").read_text().strip()})
        if not r["success"]:
            print(f"  ! {zone}: origin-pull cert upload failed: {r['errors']}")
            return
    r = cf("PUT", f"/zones/{zid}/origin_tls_client_auth/settings", {"enabled": True})
    if not r["success"]:
        print(f"  ! {zone}: enabling origin pulls failed: {r['errors']}")


summary = {}
for zone, names in ZONES.items():
    z = zone_id(zone)
    if z is None:
        continue
    zid = z["id"]
    existing = cf("GET", f"/zones/{zid}/dns_records?per_page=500")["result"]
    have = {(r["name"], r["type"], r.get("content", "")) for r in existing}
    added = 0
    # Mirror only while the zone is pending, i.e. while public DNS still comes
    # from Namecheap. Once active, public DNS IS this zone (and returns
    # Cloudflare proxy IPs for cut-over hosts), so re-mirroring would add bogus
    # DNS-only records next to the real ones.
    for n in (names if z["status"] == "pending" else []):
        fqdn = zone if n == "@" else f"{n}.{zone}"
        cname = doh(fqdn, "CNAME")
        types = ["CNAME"] if cname else [t for t in TYPES if t != "CNAME"]
        for t in types:
            for a in doh(fqdn, t):
                body = record_body(fqdn, t, a["data"], a.get("TTL", 300))
                key = (fqdn, t, body.get("content", ""))
                if key in have:
                    continue
                r = cf("POST", f"/zones/{zid}/dns_records", body)
                if r["success"]:
                    added += 1
                    have.add(key)
                else:
                    print(f"  ! {fqdn} {t} {a['data']}: {r['errors']}")
    # Origin serves real Let's Encrypt certs (DNS-01), so strict validation works.
    cf("PATCH", f"/zones/{zid}/settings/ssl", {"value": "strict"})
    ensure_origin_pull(zid, zone)
    summary[zone] = {"id": zid, "status": z["status"], "name_servers": z.get("name_servers"), "records_added": added}

print(json.dumps(summary, indent=2))
