#!/usr/bin/env python3
"""Cloudflare Cache Rules: serve anonymous visitors from Cloudflare's edge for a few seconds, for every site that
allows it (`edge_cache:` in sites.yaml). The docs (Components → Edge) explain the why and the safety rules.

A page served from the edge costs the server nothing (no CPU, no RAM): the point is that a crowd of visitors who come,
look and leave is answered by Cloudflare, and the server renders each page at most about once per TTL.

Cached only when ALL of these hold (the same for every site, so it is safe without knowing each app's cookies):
  - GET or HEAD;
  - no Cookie header at all (anyone logged in, or holding any session, goes to the origin; so do the monitoring probes,
    which send `Cookie: monitoring=1`);
  - no Authorization header (basic auth, tokens: an answer for someone);
  - not a Next.js in-app navigation request (the RSC header, or `_rsc=` in the query: another format at the same URL);
  - the path doesn't contain "/api" (unless listed in `allow_api`), nor any `exclude` prefix;
and Cloudflare itself never caches a response that sets a cookie. The edge TTL overrides the app's `no-store`
(browsers still honour the app's own headers).

sites.yaml, per namespace: `edge_cache: false`, or `edge_cache: { ttl: <s>, hosts: [...] (default: the namespace's
hosts), exclude: [path prefixes], allow_api: [path prefixes under /api], ttl_by_host: {host: s},
ttl_paths: {exact path: s}, warm: [paths for the edge-warmer], purge_on_change: {db, query} }`.

Idempotent: replaces each zone's http_request_cache_settings ruleset with the generated rules (zones with no
cacheable site get an empty ruleset). Usage: scripts/cloudflare-cache-rules.py [--dry-run]
(CLOUDFLARE_API_TOKEN from the environment or anvil.env; scope incl. Cache Settings Edit).
"""
import json
import os
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import anvil_env  # noqa: E402
import sites  # noqa: E402
DRY = "--dry-run" in sys.argv


def token():
    t = os.environ.get("CLOUDFLARE_API_TOKEN") or anvil_env.load().get("CLOUDFLARE_API_TOKEN")
    if not t:
        sys.exit("no CLOUDFLARE_API_TOKEN (anvil.env)")
    return t


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def rule(ns, hosts, ttl, exclude, allow_api):
    cond = [f"http.host in {{{' '.join(q(h) for h in hosts)}}}",
            'http.request.method in {"GET" "HEAD"}',
            'http.cookie eq ""',
            'not any(lower(http.request.headers.names[*])[*] in {"authorization" "rsc" "next-router-state-tree"})',
            'not http.request.uri.query contains "_rsc="']
    api = 'http.request.uri.path contains "/api"'
    if allow_api:
        api = f"({api} and not ({' or '.join(f'starts_with(http.request.uri.path, {q(p)})' for p in allow_api)}))"
    cond.append(f"not {api}")
    cond += [f"not starts_with(http.request.uri.path, {q(p)})" for p in exclude]
    return {
        "description": f"{ns}: anonymous visitors from the edge for {ttl}s ({', '.join(hosts)}) [sites.yaml edge_cache]",
        "expression": "(" + " and ".join(cond) + ")",
        "action": "set_cache_settings",
        "action_parameters": {"cache": True, "edge_ttl": {"mode": "override_origin", "default": ttl},
                              "browser_ttl": {"mode": "respect_origin"}},
        "enabled": True,
    }


# Build files and resized images: the same for every visitor (hashed names; /_next/image is keyed by source, width
# and quality), so cached a day also for visitors with cookies. The origin says max-age=60 for /_next/image, which
# made each phone width a MISS and a server-side resize (~1.3 s for a blog's header image) every few minutes.
# A deploy or content purge clears them anyway (purge everything).
ASSET_PREFIXES = ["/_next/static/", "/_next/image", "/_astro/"]
ASSET_TTL = 86400


def asset_rule(ns, hosts):
    return {
        "description": f"{ns}: build files and resized images for {ASSET_TTL}s, everyone ({', '.join(hosts)}) [ASSET_PREFIXES]",
        "expression": "(" + " and ".join([f"http.host in {{{' '.join(q(h) for h in hosts)}}}",
                                         'http.request.method in {"GET" "HEAD"}',
                                         "(" + " or ".join(f"starts_with(http.request.uri.path, {q(p)})" for p in ASSET_PREFIXES) + ")"]) + ")",
        "action": "set_cache_settings",
        "action_parameters": {"cache": True, "edge_ttl": {"mode": "override_origin", "default": ASSET_TTL},
                              "browser_ttl": {"mode": "respect_origin"}},
        "enabled": True,
    }


def build():
    s = sites.load()   # ${ANVIL_*} expanded
    zones = list(s["zones"])
    out = {z: [] for z in zones}
    for ns, v in s["namespaces"].items():
        ec = v.get("edge_cache")
        if not ec:
            continue
        hosts = ec.get("hosts") or v.get("hosts") or []
        by_ttl = {}
        for h in hosts:
            by_ttl.setdefault(int((ec.get("ttl_by_host") or {}).get(h, ec.get("ttl", 30))), []).append(h)
        for ttl, hs in sorted(by_ttl.items()):
            for z in zones:
                zh = [h for h in hs if h == z or h.endswith("." + z)]
                if zh:
                    out[z].append(rule(ns, zh, ttl, ec.get("exclude") or [], ec.get("allow_api") or []))
        # ttl_paths: {path: ttl}, exact paths with their own TTL (e.g. a home page that lists new posts): a second rule
        # after the first, which Cloudflare applies on top (the later matching rule's TTL wins).
        for path, ttl in (ec.get("ttl_paths") or {}).items():
            for z in zones:
                zh = [h for h in hosts if h == z or h.endswith("." + z)]
                if zh:
                    r = rule(ns, zh, int(ttl), ec.get("exclude") or [], ec.get("allow_api") or [])
                    r["expression"] = r["expression"][:-1] + f" and http.request.uri.path eq {q(path)})"
                    r["description"] = f"{ns}: {path} for {ttl}s ({', '.join(zh)}) [sites.yaml edge_cache.ttl_paths]"
                    out[z].append(r)
        for z in zones:  # last, so its TTL wins over the page rules for these paths
            zh = [h for h in hosts if h == z or h.endswith("." + z)]
            if zh:
                out[z].append(asset_rule(ns, zh))
    return out


def cf(method, path, body=None, tok=None):
    req = urllib.request.Request("https://api.cloudflare.com/client/v4" + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)


def main():
    rules = build()
    if DRY:
        for z, rs in rules.items():
            for r in rs:
                print(f"{z}: {r['description']}\n    {r['expression']}")
        return
    tok = token()
    for z, rs in rules.items():
        found = cf("GET", f"/zones?name={z}", tok=tok).get("result") or []
        if not found:
            print(f"{z}: no such zone (skipped)")
            continue
        zid = found[0]["id"]
        r = cf("PUT", f"/zones/{zid}/rulesets/phases/http_request_cache_settings/entrypoint", {"rules": rs}, tok=tok)
        if not r.get("success"):
            sys.exit(f"{z}: {r.get('errors')}")
        tiered = ""
        if rs:  # Tiered Cache (free): edge locations fetch from an upper tier near the origin, not from the server
            a1 = cf("PATCH", f"/zones/{zid}/argo/tiered_caching", {"value": "on"}, tok=tok)
            a2 = cf("PATCH", f"/zones/{zid}/cache/tiered_cache_smart_topology_enable", {"value": "on"}, tok=tok)
            tiered = ", tiered cache on" if a1.get("success") and a2.get("success") else f", TIERED CACHE FAILED: {a1.get('errors') or a2.get('errors')}"
        print(f"{z}: {len(r['result'].get('rules', []))} cache rule(s){tiered}")


if __name__ == "__main__":
    main()
