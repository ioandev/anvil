"""Reduce k6's per-request CSV output to 10-second buckets (run on the k6 machine, in a python container, by
scripts/loadtest <ns> run). Reads /k6/metrics.csv.gz, writes /k6/series.json:
  {"bucket": 10, "start": <epoch>, "rows": [{"t": <seconds from start>, "reqs": {kind: n}, "failed": {kind: n},
   "status": {"2xx": n, "4xx": n, "5xx": n, "err": n}, "lat": {kind: {"p50", "p95", "p99", "max"}}, "vus": n,
   "dropped": n, "iterations": n, "rx_mb": x}], "errors": {error text: n}}
"""
import csv, gzip, json, sys
from collections import defaultdict

B = 10
reqs, failed, status, lat, vus, dropped, iters, rx, errors = (defaultdict(lambda: defaultdict(int)), defaultdict(lambda: defaultdict(int)),
    defaultdict(lambda: defaultdict(int)), defaultdict(lambda: defaultdict(list)), {}, defaultdict(int), defaultdict(int),
    defaultdict(float), defaultdict(int))
start = None


def kind_of(extra):
    for part in (extra or "").split("&"):
        if part.startswith("kind="):
            return part[5:]
    return "other"


with gzip.open(sys.argv[1] if len(sys.argv) > 1 else "/k6/metrics.csv.gz", "rt", newline="") as f:
    r = csv.DictReader(f)
    for row in r:
        m = row["metric_name"]
        try:
            ts = int(float(row["timestamp"]))
        except (TypeError, ValueError):
            continue
        if start is None or ts < start:
            start = ts if start is None else start
        b = ts // B
        if m == "http_req_duration":
            k = kind_of(row.get("extra_tags"))
            lat[b][k].append(float(row["metric_value"]))
        elif m == "http_reqs":
            k = kind_of(row.get("extra_tags"))
            reqs[b][k] += 1
            s = row.get("status") or "0"
            status[b]["2xx" if s.startswith("2") else "4xx" if s.startswith("4") else "5xx" if s.startswith("5") else "err"] += 1
            if row.get("error"):
                errors[row["error"][:120]] += 1
        elif m == "http_req_failed" and row["metric_value"] in ("1", "1.0", "1.000000"):
            failed[b][kind_of(row.get("extra_tags"))] += 1
        elif m == "vus":
            vus[b] = max(vus.get(b, 0), int(float(row["metric_value"])))
        elif m == "dropped_iterations":
            dropped[b] += 1
        elif m == "iterations":
            iters[b] += 1
        elif m == "data_received":
            rx[b] += float(row["metric_value"]) / 1e6


def pct(v, p):
    if not v:
        return None
    v.sort()
    return round(v[min(len(v) - 1, int(len(v) * p))], 1)


bs = sorted(set(reqs) | set(lat) | set(vus))
b0 = bs[0] if bs else 0
rows = []
for b in bs:
    rows.append({"t": (b - b0) * B, "reqs": dict(reqs[b]), "failed": dict(failed[b]), "status": dict(status[b]),
                 "lat": {k: {"p50": pct(v, .5), "p95": pct(v, .95), "p99": pct(v, .99), "max": round(max(v), 1)}
                         for k, v in lat[b].items()}, "vus": vus.get(b, 0), "dropped": dropped[b],
                 "iterations": iters[b], "rx_mb": round(rx[b], 2)})
json.dump({"bucket": B, "start": b0 * B, "rows": rows, "errors": dict(sorted(errors.items(), key=lambda x: -x[1])[:20])},
          open("/k6/series.json", "w"))
print(f"{len(rows)} buckets, {sum(sum(r['reqs'].values()) for r in rows)} requests")
