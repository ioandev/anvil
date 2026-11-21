---
name: 10-secrets
description: Second anvil bootstrap step. Creates the age key and .sops.yaml, generates every random secret (database passwords, status code, tokens), the origin-pull CA and the SSH key, and encrypts all of it for git. Use after 00-preflight passes.
---

# 10-secrets: generate everything nobody should type

Idempotent: never changes a value that is already set.

1. `scripts/anvil-secrets init`: age key (if missing) + `.sops.yaml`, every generated value in `anvil.env`
   (STATUS_CODE, WEBHOOK_TOKEN, ALERT_SERVICE_PASSWORD, GRAFANA_ADMIN_PASSWORD, ATLAS_*, HEALTH_DB_PASSWORD, each
   project's `<NS>_RW/RO_PASSWORD`), the apps' `generate:` keys (sites.yaml) in `apps/<ns>/prod.env`, then encrypts.
2. **Stop and ask the owner** to copy `~/.config/sops/age/keys.txt` into their password manager, and to confirm.
   Without it, a lost laptop = every secret in git is lost.
3. `scripts/origin-pull-ca`: our own CA + the client certificate Cloudflare will present (Authenticated Origin Pulls).
4. `make ssh-key` (ed25519 at `~/.ssh/id_ed25519_anvil`; the server only accepts this key).
5. `make hooks` (pre-commit: re-encrypts secrets, refuses plaintext, runs `sites.py check`), then
   `make secrets-encrypt` and `scripts/secrets.sh check`.

Verify: `scripts/secrets.sh check` passes; `git status` shows only `.sops` twins and no plaintext secret;
`scripts/anvil-secrets missing` prints nothing. Never print a generated value.
