# anvil

**One cheap cloud server that runs many small projects safely, tells you when something breaks, and fixes what it
can by itself.** Reproducible from this repo in under an hour, torn down in minutes.

- **Server:** one Scaleway instance (Flatcar Linux, single-node k3s), created with Terraform. Only Cloudflare can
  reach it on 80/443, and only with **our own** client certificate. SSH is key-only on a custom port.
- **Edge:** Cloudflare Free, with Origin CA certificates (no ACME, no Cloudflare token on the server) and a `www.`
  redirect for every site.
- **Data:** one shared MariaDB with two least-privilege users per project. Nightly off-site backups use a
  **write-only** key, so the server can't delete its own backups. A morning check, and a weekly "backups OK" email.
- **Secrets:** in git, encrypted with SOPS + age. One age key is the root of trust.
- **Knowing it broke:** Prometheus probes every site through Cloudflare every 30 s, and kube-state-metrics watches
  every workload. Alerts become **phone calls** (Twilio), with back-off, quiet hours and voicemail detection. A
  watchdog on a home machine calls you if the server itself disappears. Status pages: `status.<domain>`.
- **Fixing it:** the **autopilot**, Claude Code in a container on the home machine, wakes on alerts. It may only
  restart, roll back, re-run a job or delete one stuck pod. It holds the phone calls while it works, reports what it
  did, and gives up loudly if it can't fix the problem.
- **Operated with Claude Code:** `CLAUDE.md` holds the rules every app follows; skills cover the bootstrap,
  image updates and audits.

## Quick start (about an hour, mostly waiting for DNS)

You need: a domain, a Scaleway account, a Cloudflare account, a Twilio account with a number, a Tailscale tailnet, an
Anthropic API key (with a spend limit), and an always-on home machine with Docker (a Mac mini works).

Install from **your own private copy**, never from anvil itself: the bootstrap commits your platform's encrypted
secrets and server state into the repository you run it in. Make a private repository from this template, keep this
one as `upstream` for updates (`git pull upstream main`), and see Quickstart → Your own copy first.

```sh
git clone git@github.com:<you>/<your-platform>.git && cd <your-platform>   # your private copy
git remote add upstream https://github.com/ioandev/anvil.git
scripts/anvil-secrets init          # creates anvil.env, your age key, every generated secret
$EDITOR anvil.env                   # fill in part 1 (accounts and keys)
claude                              # then: "run the anvil bootstrap skills in order"
```

The skills in `.claude/skills/` run in this order. Each one checks its own result and is safe to re-run:

| Step | What it does |
|---|---|
| `00-preflight` | tools, accounts and tokens; prints the cost before anything exists |
| `10-secrets` | age key, generated passwords and codes, origin-pull CA, SSH key |
| `20-cloudflare` | zone, nameservers (API or a HUMAN.md task), edge cert, Origin CA cert |
| `30-infra` | Terraform: image import, server, IP, firewall; waits for k3s |
| `40-platform` | registry, backup bucket + write-only key, images, secrets, the shared stack |
| `50-demo-app` | the demo app, DNS cutover, checks from outside |
| `60-alerts` | a test call (with your OK), the home watchdog |
| `70-autopilot` | vault, autopilot, and a live break-and-fix test |
| `80-verify` | everything green, including a restore test |
| `99-teardown` | deletes everything, checks nothing billable is left |

## Layout

```
infra/            Terraform + Butane (first boot) + node manifests + state (encrypted twin in git)
platform/<ns>/    the shared stack: alerting, webhook (status), atlas (MariaDB), origin-ca, www, dozzle, backup
apps/<ns>/        projects (apps/anvil-demo: the demo)
sites.yaml        every site's zone, hosts, probes, database, UID block (scripts/sites.py check|render)
demo/             the demo app's source (TypeScript)
images/           other images we build (twilio-alert)
mac/              the home machine: watchdog, autopilot, vault, backup pull
scripts/          node.sh (operate the server), new-site, make-secrets, secrets.sh, cutover, …
docs/             the documentation website (Astro Starlight)
.claude/skills/   the bootstrap steps and operations skills
```

Everyday commands: `make check`, `make apps`, `scripts/node.sh deploy <ns>`, `scripts/new-site init|plan|apply`,
`scripts/node.sh kubectl …`. Full documentation: `docs/` (or the published site).

## Costs (example, at the time of writing)

A DEV1-L (4 vCPU, 8 GB, 80 GB local SSD) is about €30/month, including its disk. The IPv4 is about €3/month, and
object storage for backups costs cents. Twilio is a few cents per call. Claude costs only when the autopilot runs.
A one-hour trial, torn down afterwards, costs well under €1.

## Origin

anvil is the generic version of a personal platform that has run about 20 projects since October 2026.
The rules in `CLAUDE.md` each come from something that went wrong there; `docs/` → Lessons learned tells those
stories.
