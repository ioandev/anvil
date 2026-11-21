"""anvil.env: the one settings + secrets file (gitignored; encrypted twin anvil.env.sops), and ${ANVIL_*} expansion.

Every script reads settings through here. Manifests, sites.yaml and the Grafana/Prometheus configs may contain
${ANVIL_NAME}-style variables; expand() replaces exactly those (other ${...}, e.g. Grafana's own, are left alone)
and fails on an ANVIL_ variable that isn't set, so a typo never reaches the cluster as literal text.
"""
import os, pathlib, re

REPO = pathlib.Path(__file__).resolve().parent.parent
ENV_FILE = REPO / "anvil.env"
EXAMPLE = REPO / "anvil.env.example"
VAR = re.compile(r"\$\{(ANVIL_[A-Z0-9_]+)\}")


def parse(path):
    out = {}
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.split(" #", 1)[0].strip().strip('"').strip("'")
    return out


def load(example_ok=False):
    """anvil.env merged over the process environment (the file wins). example_ok: fall back to anvil.env.example
    (for checks on a fresh clone: placeholders, no secrets)."""
    src = ENV_FILE if ENV_FILE.exists() else (EXAMPLE if example_ok else None)
    if src is None:
        raise SystemExit("anvil.env not found: run the 10-secrets step (scripts/anvil-secrets init)")
    env = {k: v for k, v in os.environ.items() if k.startswith("ANVIL_")}
    env.update(parse(src))
    return env


OPTIONAL = {"ANVIL_REPO_URL"}   # may be empty: the autopilot then works without a clone of the repo


def expand(text, env=None, where="text"):
    env = env if env is not None else load(example_ok=True)
    # Empty counts as missing (a value left unfilled), except settings that may be empty on purpose.
    missing = sorted({m for m in VAR.findall(text) if not env.get(m) and not (m in OPTIONAL and m in env)})
    if missing:
        raise SystemExit(f"{where}: not set in anvil.env: {', '.join(missing)}")
    return VAR.sub(lambda m: env[m.group(1)], text)


def export():
    """Put anvil.env's values into os.environ (values already in the environment win), for scripts that read
    credentials from the environment (CLOUDFLARE_API_TOKEN, SCW_*, ...)."""
    if ENV_FILE.exists():
        for k, v in parse(ENV_FILE).items():
            os.environ.setdefault(k, v)
