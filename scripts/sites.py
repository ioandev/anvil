#!/usr/bin/env python3
"""sites.yaml as a library and a CLI: the one source for zones, hosts, www redirects, probes, databases, UIDs,
ConfigMaps and generated app secrets. ${ANVIL_*} in sites.yaml and the manifests are expanded from anvil.env;
the generated parts of the templates keep them unexpanded (the repo stays generic).


  python3 -I scripts/sites.py render         rewrite the generated parts (www route, TLSStore list, CLAUDE.md table)
  python3 -I scripts/sites.py check          manifests vs sites.yaml; exit 1 on errors (warnings don't fail)
  python3 -I scripts/sites.py hosts <ns>     its hosts (+ www.<host> for its www list), for scripts/cutover.py
  python3 -I scripts/sites.py db <ns>        its database name (empty if none)
  python3 -I scripts/sites.py dbs            {ns: db} as JSON
  python3 -I scripts/sites.py zones          one zone per line
  python3 -I scripts/sites.py manifest <ns>  its app.yaml with ${ANVIL_*} expanded (what `node.sh deploy` applies)

Library (scripts on sys.path): `import sites; sites.dbs(); sites.probes(); sites.zones(); sites.nsdir(ns)`.
"""
import json, os, pathlib, re, sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import anvil_env  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parent.parent
SITES = REPO / "sites.yaml"
GENERATED = "generated from sites.yaml by scripts/sites.py render: edit sites.yaml, not this"


def load(raw=False):
    """sites.yaml with ${ANVIL_*} expanded from anvil.env (raw=True: as written, for the generated template parts)."""
    text = SITES.read_text()
    return yaml.safe_load(text if raw else anvil_env.expand(text, where="sites.yaml"))


def namespaces(raw=False):
    return load(raw)["namespaces"]


def nsdir(ns):
    """A namespace's folder: platform/<ns> (the shared stack) or apps/<ns> (projects)."""
    return f"platform/{ns}" if (REPO / "platform" / ns).is_dir() else f"apps/{ns}"


def zones(raw=False):
    return list(load(raw)["zones"])


def zone_records():
    return {z: v.get("records", []) for z, v in load()["zones"].items()}


def dbs():
    return {ns: v["db"] for ns, v in namespaces().items() if v.get("db")}


def moves():
    """Projects whose database can move to its own server (sites.yaml `move:`): {ns: move settings}."""
    return {ns: v["move"] for ns, v in namespaces().items() if v.get("move")}


def render_binlog():
    """atlas's --binlog-do-db lines: only the databases of projects with `move:` are ever in the binary log (a sync
    login and the receiving server must never see other projects' changes). None: a name no database has."""
    data = load(raw=True)["namespaces"]
    dbs = sorted(v["db"] for v in data.values() if v.get("move") and v.get("db"))
    return "".join(f"            - --binlog-do-db={db}\n" for db in (dbs or ["no_database_moves"]))


def probes():
    """{url: namespace} for the blackbox 'sites' job."""
    return {u: ns for ns, v in namespaces().items() for u in v.get("probes", [])}


def www_hosts(raw=False):
    return sorted(f"www.{h}" for v in namespaces(raw).values() for h in v.get("www", []))


def hosts(ns):
    v = namespaces()[ns]
    return v.get("hosts", []) + [f"www.{h}" for h in v.get("www", []) if f"www.{h}" not in v.get("hosts", [])]


def uid_ranges(ns):
    out = []
    for r in namespaces()[ns].get("uids", []):
        a, _, b = str(r).partition("-")
        out.append((int(a), int(b or a)))
    return out


# --- manifests ---------------------------------------------------------------------------------------------------

def manifest(ns):
    """The namespace's app.yaml with ${ANVIL_*} expanded (what `node.sh deploy` applies)."""
    f = REPO / nsdir(ns) / "app.yaml"
    return anvil_env.expand(f.read_text(), where=str(f.relative_to(REPO))) if f.exists() else ""


def manifest_docs(ns):
    return [d for d in yaml.safe_load_all(manifest(ns)) if d]


def configmaps(ns):
    """{name: folder or file}: ConfigMaps built from repo files at deploy (sites.yaml `configmaps:`)."""
    return namespaces()[ns].get("configmaps") or {}


def generated(ns):
    """Keys of apps/<ns>/prod.env that scripts/anvil-secrets fills with random values (sites.yaml `generate:`)."""
    return namespaces()[ns].get("generate") or []


def tls_secret(zone):
    """Name of a zone's Origin CA TLS secret (dots kept: valid, and the same raw or expanded)."""
    return f"origin-ca-{zone}"


def pod_specs(ns):
    """(kind, workload name, pod spec) for every pod template in the namespace's manifest."""
    for d in manifest_docs(ns):
        k, s = d.get("kind"), d.get("spec") or {}
        if k in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
            yield k, d["metadata"]["name"], s["template"]["spec"]
        elif k == "CronJob":
            yield k, d["metadata"]["name"], s["jobTemplate"]["spec"]["template"]["spec"]


def manifest_hosts(ns):
    hs = set()
    for d in manifest_docs(ns):
        if d.get("kind") == "Ingress":
            hs.update(r["host"] for r in d["spec"].get("rules", []) if r.get("host"))
        elif d.get("kind") == "IngressRoute":
            for r in d["spec"].get("routes", []):
                hs.update(re.findall(r"Host\(`([^`]+)`\)", r.get("match", "")))
    return hs


def containers(ns):
    """(workload, container, uid, gid, fsGroup, supplementalGroups) for every container."""
    for _, w, spec in pod_specs(ns):
        psc = spec.get("securityContext") or {}
        for c in spec.get("initContainers", []) + spec.get("containers", []):
            sc = {**psc, **(c.get("securityContext") or {})}
            yield (w, c["name"], sc.get("runAsUser"), sc.get("runAsGroup"), psc.get("fsGroup"),
                   psc.get("supplementalGroups") or [])


# --- render -------------------------------------------------------------------------------------------------------

def _replace_region(path, begin, end, body):
    p = REPO / path
    s = p.read_text()
    i, j = s.find(begin), s.find(end)
    if i < 0 or j < i:
        raise SystemExit(f"{path}: markers not found ({begin!r} … {end!r})")
    new = s[:i + len(begin)] + "\n" + body + s[j:]
    if new != s:
        p.write_text(new)
        return True
    return False


def render_www():
    if not www_hosts(raw=True):
        return "# (no site has `www:` in sites.yaml, so there is no redirect route)\n"
    match = " || ".join(f"Host(`{h}`)" for h in www_hosts(raw=True))
    return f"""apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {{ name: www-redirect, namespace: www, labels: {{ app.kubernetes.io/part-of: www, app.kubernetes.io/managed-by: anvil, anvil/tier: platform }} }}
spec:
  entryPoints: [websecure]
  routes:
    - kind: Rule
      match: >-
        {match}
      middlewares: [{{ name: redirect-to-apex }}]
      services: [{{ name: noop@internal, kind: TraefikService }}]
  tls: {{}}
"""


def render_tlsstore():
    return "".join(f"    - secretName: {tls_secret(z)}\n" for z in zones(raw=True))


def render_table():
    rows = ["| Namespace | Public hosts | Workload (container) → UID:GID |", "|---|---|---|"]
    for ns, v in namespaces(raw=True).items():
        hs = ", ".join(v.get("hosts", [])) or ""
        note = v.get("notes", "")
        hosts_cell = f"{hs} ({note})" if hs and note else (hs or (f"({note})" if note else ""))
        by_uid = {}
        for w, c, uid, gid, fs, sup in containers(ns):
            label = w if all(x[2] == uid for x in containers(ns) if x[0] == w) else f"{w}/{c}"
            key = f"{uid}" + ("" if gid in (None, uid) else f":{gid}")
            extra = [str(g) for g in sup if g != uid]
            if extra:
                key += " (+group " + ", ".join(extra) + ")"
            by_uid.setdefault(key, [])
            if label not in by_uid[key]:
                by_uid[key].append(label)
        parts = [f"{' / '.join(ls)} {u}" for u, ls in sorted(by_uid.items())]
        parts += [f"{u}: {n}" for u, n in (v.get("uid_notes") or {}).items()]
        rows.append(f"| {ns} | {hosts_cell} | {' · '.join(parts)} |")
    return "\n".join(rows) + "\n"


def render_warmer():
    """The edge-warmer's lists: "<ttl> <url>" for every warm URL of every edge_cache site, and "zone|db|user|query"
    for every purge_on_change (raw: ${ANVIL_*} stay as written and are expanded at deploy)."""
    data = load(raw=True)
    lines, purge = [], []
    for ns, v in data["namespaces"].items():
        ec = v.get("edge_cache")
        if not ec:
            continue
        hosts = ec.get("hosts") or v.get("hosts") or []
        for h in hosts:
            ttl = int((ec.get("ttl_by_host") or {}).get(h, ec.get("ttl", 30)))
            for path in ec.get("warm") or ["/"]:
                lines.append(f"{int((ec.get('ttl_paths') or {}).get(path, ttl))} https://{h}{path}")
        pc = ec.get("purge_on_change")
        if pc:
            for z in sorted({z for h in hosts for z in data["zones"] if h == z or h.endswith("." + z)}):
                purge.append(f"{z}|{pc['db']}|{ns.replace('-', '_')}_ro|{pc['query']}")
    return ("  urls.txt: |\n" + "".join(f"    {l}\n" for l in lines)
            + "  purge.txt: |\n" + "".join(f"    {l}\n" for l in purge))


def render():
    changed = []
    if _replace_region("platform/www/app.yaml", f"# BEGIN {GENERATED}", "# END generated", render_www()):
        changed.append("platform/www/app.yaml")
    if _replace_region("platform/origin-ca/app.yaml", f"    # BEGIN {GENERATED}", "    # END generated",
                       render_tlsstore()):
        changed.append("platform/origin-ca/app.yaml")
    if _replace_region("platform/atlas/app.yaml", f"            # BEGIN {GENERATED}", "            # END generated", render_binlog()):
        changed.append("platform/atlas/app.yaml")
    if _replace_region("platform/edge-warmer/app.yaml", f"  # BEGIN {GENERATED}", "  # END generated", render_warmer()):
        changed.append("platform/edge-warmer/app.yaml")
    if _replace_region("CLAUDE.md", f"<!-- BEGIN {GENERATED} -->", "<!-- END generated -->", render_table()):
        changed.append("CLAUDE.md")
    return changed


# --- check --------------------------------------------------------------------------------------------------------

def check():
    errors, warnings = [], []
    data = load()
    nss, zs = data["namespaces"], data["zones"]
    on_disk = {p.parent.name for p in list(REPO.glob("apps/*/app.yaml")) + list(REPO.glob("platform/*/app.yaml"))}
    for ns in sorted(on_disk - set(nss)):
        errors.append(f"{nsdir(ns)}/app.yaml has no entry in sites.yaml")
    for ns in sorted(set(nss) - on_disk):
        if nss[ns].get("scripted"):   # created by a script (e.g. a load-test copy), no app.yaml of its own
            continue
        errors.append(f"sites.yaml lists {ns}, but {nsdir(ns)}/app.yaml doesn't exist")
    owner = {}
    for ns, v in nss.items():
        if ns not in on_disk:
            continue
        if v.get("tier") not in ("platform", "app"):
            errors.append(f"{ns}: tier must be platform or app")
        elif nsdir(ns).split("/")[0] != {"platform": "platform", "app": "apps"}[v["tier"]]:
            errors.append(f"{ns}: tier {v['tier']} but it lives in {nsdir(ns)}/")
        declared = set(hosts(ns)) if ns != "www" else set(www_hosts())
        for h in sorted(manifest_hosts(ns) - declared):
            errors.append(f"{ns}: its manifest answers {h}, which sites.yaml doesn't list for it")
        for h in v.get("hosts", []) + v.get("www", []):
            if not any(h == z or h.endswith("." + z) for z in zs):
                errors.append(f"{ns}: host {h} is in no zone listed in sites.yaml")
        rs = uid_ranges(ns) if v.get("uids") else []
        for a, b in rs:
            for o_ns, (oa, ob) in owner.items():
                if a <= ob and oa <= b:
                    errors.append(f"UID ranges overlap: {ns} {a}-{b} and {o_ns.split('#')[0]} {oa}-{ob}")
            owner[f"{ns}#{a}"] = (a, b)
        inside = lambda x: any(a <= x <= b for a, b in rs)  # noqa: E731
        for w, c, uid, gid, fs, sup in containers(ns):
            if uid is None or gid is None:
                errors.append(f"{ns}: {w}/{c} has no explicit runAsUser/runAsGroup (rule 3)")
                continue
            for what, x in (("runAsUser", uid), ("runAsGroup", gid), ("fsGroup", fs)) + tuple(("supplementalGroup", g) for g in sup):
                if x is not None and not inside(x):
                    errors.append(f"{ns}: {w}/{c} {what} {x} is outside its UID blocks {v.get('uids')}")
                if x in data.get("retired_uids", []):
                    errors.append(f"{ns}: {w}/{c} uses retired UID {x}")
        for k, w, spec in pod_specs(ns):
            if spec.get("enableServiceLinks") is not False:
                errors.append(f"{ns}: {w} lacks enableServiceLinks: false (rule 5)")
            for c in spec.get("containers", []) + spec.get("initContainers", []):
                sc = c.get("securityContext") or {}
                if sc.get("privileged"):
                    errors.append(f"{ns}: {w}/{c['name']} is privileged (rule 20)")
                if sc.get("allowPrivilegeEscalation") is not False:
                    errors.append(f"{ns}: {w}/{c['name']} lacks allowPrivilegeEscalation: false (rule 20)")
            for c in spec.get("containers", []):
                if c.get("readinessProbe") and not c.get("livenessProbe"):
                    warnings.append(f"{ns}: {w}/{c['name']} has a readinessProbe but no livenessProbe (rule 11)")
                lp = c.get("livenessProbe") or {}
                if lp:
                    # rule 11: restart only after 2.5 min of silence (a slow-but-alive app on a busy node must not be killed);
                    # a startupProbe covers slow starts, so then initialDelaySeconds may be lower
                    short = [f"{k}={lp.get(k, d)} (want >= {want})" for k, d, want in (
                        ("timeoutSeconds", 1, 10), ("failureThreshold", 3, 5), ("periodSeconds", 10, 30),
                        ("initialDelaySeconds", 0, 0 if c.get("startupProbe") else 120)) if lp.get(k, d) < want]
                    if short:
                        warnings.append(f"{ns}: {w}/{c['name']} liveness probe is quicker than rule 11: {', '.join(short)}")
        if v.get("tier") == "app" and v.get("hosts") and "edge_cache" not in v:
            warnings.append(f"{ns}: public hosts but no edge_cache decision (rule 19: a ttl, or false with a reason)")
        if v.get("tier") == "app" and v.get("hosts") and not v.get("probes") and "probed by" not in v.get("notes", ""):
            warnings.append(f"{ns}: public hosts but no probes (rule 13)")
    for u in data.get("retired_uids", []):
        if u >= data.get("next_uid_block", 0):
            errors.append(f"retired UID {u} is above next_uid_block")
    top = max((b for a, b in owner.values()), default=0)
    if data.get("next_uid_block", 0) <= top:
        errors.append(f"next_uid_block {data.get('next_uid_block')} is not above the highest block in use ({top})")
    # Service names (= in-cluster hostnames) unique across the cluster (rule 2)
    seen = {}
    for ns in on_disk:
        for d in manifest_docs(ns):
            if d.get("kind") == "Service":
                seen.setdefault(d["metadata"]["name"], []).append(ns)
    for name, where in sorted(seen.items()):
        if len(where) > 1:
            errors.append(f"Service name {name} is used in several namespaces: {', '.join(sorted(where))} (rule 2)")
    # rendered parts current
    for path, begin, end, body in (
            ("platform/www/app.yaml", f"# BEGIN {GENERATED}", "# END generated", render_www()),
            ("platform/origin-ca/app.yaml", f"    # BEGIN {GENERATED}", "    # END generated", render_tlsstore()),
            ("CLAUDE.md", f"<!-- BEGIN {GENERATED} -->", "<!-- END generated -->", render_table())):
        s = (REPO / path).read_text()
        i, j = s.find(begin), s.find(end)
        if i < 0 or j < i:
            errors.append(f"{path}: generated-region markers missing")
        elif s[i + len(begin) + 1:j] != body:
            errors.append(f"{path}: generated part is out of date (run scripts/sites.py render)")
    return errors, warnings


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "check"
    if cmd == "render":
        ch = render()
        print("rewrote: " + ", ".join(ch) if ch else "nothing to change")
    elif cmd == "check":
        errors, warnings = check()
        for w in warnings:
            print("warning:", w)
        for e in errors:
            print("ERROR:", e)
        print(f"sites check: {len(errors)} error(s), {len(warnings)} warning(s)")
        return 1 if errors else 0
    elif cmd == "hosts":
        print("\n".join(hosts(argv[2])))
    elif cmd == "db":
        print(dbs().get(argv[2], ""))
    elif cmd == "dbs":
        print(json.dumps(dbs()))
    elif cmd == "zones":
        print("\n".join(zones()))
    elif cmd == "manifest":
        print(manifest(argv[2]), end="")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
