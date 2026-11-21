#!/usr/bin/env python3
"""Issue Cloudflare Origin CA certificates for every zone (zone + *.zone, 15 years).

All traffic reaches the server through Cloudflare (Authenticated Origin Pulls
enforce it), so the origin only needs a certificate Cloudflare trusts in Full
(strict) mode. That's an Origin CA cert, issued once from here, so the server
needs no ACME and no Cloudflare API token.

Keys and certs live in ORIGIN_CA_DIR (restore bundle; encrypted twins in git via
scripts/secrets.sh). Idempotent: zones that already have a cert are skipped.
Afterwards run `scripts/make-secrets.py && scripts/node.sh deploy origin-ca`.

Usage: scripts/origin-certs.py   (CLOUDFLARE_API_TOKEN from anvil.env)
"""
import json
import os
import pathlib
import subprocess
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I leaves the script's folder off sys.path
import anvil_env  # noqa: E402
anvil_env.export()  # credentials from anvil.env
import sites  # noqa: E402

TOKEN = os.environ["CLOUDFLARE_API_TOKEN"]
OUT = pathlib.Path(os.environ.get("ORIGIN_CA_DIR", str(anvil_env.REPO / ".data/origin-ca")))
ZONES = sites.zones()  # sites.yaml `zones:`


def issue(zone):
    key, crt = OUT / f"{zone}.key", OUT / f"{zone}.crt"
    if crt.exists() and crt.stat().st_size:
        return f"{zone}: exists"
    if not key.exists():
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                        "-out", str(key)], check=True, capture_output=True)
        key.chmod(0o600)
    csr = subprocess.run(["openssl", "req", "-new", "-key", str(key), "-subj", f"/CN={zone}"],
                         check=True, capture_output=True, text=True).stdout
    body = {"hostnames": [zone, f"*.{zone}"], "requested_validity": 5475,
            "request_type": "origin-ecc", "csr": csr}
    req = urllib.request.Request("https://api.cloudflare.com/client/v4/certificates", method="POST",
                                 data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        d = json.load(e)
    if not d["success"]:
        sys.exit(f"{zone}: {d['errors']}")
    crt.write_text(d["result"]["certificate"])
    return f"{zone}: issued (id {d['result']['id']}, expires {d['result']['expires_on']})"


OUT.mkdir(parents=True, exist_ok=True)
OUT.chmod(0o700)
for z in ZONES:
    print(issue(z))
