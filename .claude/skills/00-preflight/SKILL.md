---
name: 00-preflight
description: First anvil bootstrap step. Checks this machine's tools, the accounts and tokens in anvil.env (Scaleway, Cloudflare, Twilio, Tailscale, Claude), and prints what the platform will cost before anything is created. Use when setting up a new anvil platform or before re-running the bootstrap.
---

# 00-preflight: can we build, and what will it cost?

Changes nothing. Run every check, then report one table: check · result · how to fix. Stop the bootstrap if any
**required** line fails.

1. **Tools** (`command -v`, versions): `terraform` ≥ 1.8, `sops` ≥ 3.9, `age` + `age-keygen`, `python3` ≥ 3.11 with
   PyYAML (`python3 -c 'import yaml'`), `podman` (or docker: then `make images` needs editing), `openssl`, `ssh`,
   `curl`, `jq`, `git`. Optional: `scw` (Scaleway CLI), `gh`. On macOS: `brew install terraform sops age podman jq`.
   On Linux use the distribution's packages. Never `curl | sh` installers without showing the owner first.
2. **anvil.env exists** (`scripts/anvil-secrets missing` prints nothing). If it doesn't exist:
   `scripts/anvil-secrets init` creates it from `anvil.env.example`; ask the owner to fill in part 1 (never ask them
   to paste secrets into the chat: they edit the file themselves).
3. **Credentials work** (read-only calls; print only "ok"/the error, never a value):
   - Scaleway: `curl -s -H "X-Auth-Token: $SCW_SECRET_KEY" https://api.scaleway.com/account/v3/projects/$SCW_DEFAULT_PROJECT_ID`
     → 200. Also check the key has **no expiry** (IAM API: `GET /iam/v1alpha1/api-keys/$SCW_ACCESS_KEY`, `expires_at`
     null). An expiring key fails silently later.
   - Cloudflare: `GET https://api.cloudflare.com/client/v4/user/tokens/verify` → `"status":"active"`; and
     `GET /zones?name=$ANVIL_DOMAIN` (the zone may not exist yet: fine).
   - Twilio: `GET https://api.twilio.com/2010-04-01/Accounts/$TWILIO_ACCOUNT_SID.json` with the API key → 200, and
     the number is voice-capable.
   - Claude: `ANTHROPIC_API_KEY` → `POST https://api.anthropic.com/v1/messages` with a 1-token request to
     `claude-haiku-5-5` → 200 (costs a fraction of a cent); or `CLAUDE_CODE_OAUTH_TOKEN` set.
   - Tailscale: the auth key is set; `tailscale status` on this machine shows the tailnet (the home machine must be
     on it too).
   - Namecheap (optional): set → `namecheap.domains.getList` works and this machine's IP is whitelisted.
4. **The domain**: `whois`/RDAP shows it registered to the owner; note the registrar (Namecheap → 20-cloudflare can
   switch nameservers by API; others → a manual step in HUMAN.md).
5. **Home machine**: `ssh -o BatchMode=yes $ANVIL_HOME_SSH true` (key-based SSH works), Docker is running there,
   it's on the tailnet.
6. **Cost estimate** (print it; prices change, so check scaleway.com/en/pricing when unsure):
   instance `$ANVIL_INSTANCE_TYPE` (DEV1-L ≈ €0.04/h, ≈ €30/month incl. its 80 GB local SSD) + flexible IPv4
   (≈ €0.004/h) + Object Storage (≈ €0.015/GB-month; backups are small) + container registry (first 75 GB free on
   private namespaces at the time of writing) + Transactional Email (first 300 emails/month free) + Twilio
   (a few cents per call) + Claude (each autopilot run: a few cents to ~$1 with Opus; cap it with the API key's
   spend limit). **"Up for an hour and torn down" ≈ under €0.10 of Scaleway.**
7. Remind the owner: the **age key** created in 10-secrets is the only way to decrypt the secrets; it must go into
   their password manager.
