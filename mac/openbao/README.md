# OpenBao on the Mac mini

Passwords and keys for the owner and for automation (Claude). Open-source Vault fork (MPL-2.0), `openbao/openbao:2.7.2`
in Docker Desktop on `${ANVIL_HOME_SSH}`, files in `~/${ANVIL_NAME}-openbao/` (master copy here). Tailnet only:
**https://${ANVIL_HOME_TAILNET_HOST}:${ANVIL_HOME_BAO_PORT}** (`tailscale serve --https=${ANVIL_HOME_BAO_PORT}` → `127.0.0.1:${ANVIL_HOME_BAO_PORT}`; never expose it
anywhere else).

## What's where

| Thing | Where |
|---|---|
| Config | `config.hcl` (Raft storage, static auto-unseal, audit log), `docker-compose.yml` |
| Auto-unseal key (32 bytes) | `~/${ANVIL_NAME}-openbao/seal.key` on the Mac; encrypted twin `mac/openbao/seal.key.sops` here. **Key + data volume = everything readable**; lose the key and the data is gone |
| Recovery key, logins | `mac/openbao/secrets.env` (gitignored; twin `.sops`): `OPENBAO_RECOVERY_KEY` (makes a new root token: `bao operator generate-root`), `OPENBAO_OWNER_PASSWORD`, Claude's AppRole |
| Data + audit log | Docker volume `${ANVIL_NAME}-openbao_openbao-data` (`/openbao/file`; audit log `audit.log`: every request, values hashed) |
| Backups | `~/${ANVIL_NAME}-openbao-backups/openbao-*.snap`, nightly 06:30 (launchd `com.anvil.${ANVIL_NAME}-openbao-backup`, `backup.sh`, token `~/${ANVIL_NAME}-openbao/backup.token`), 30 days. Restoring needs `seal.key`. **Off-site:** each snapshot is also uploaded to the private bucket `${ANVIL_OPENBAO_BUCKET}` (fr-par, 90-day expiry) with the write-only backup key (`~/${ANVIL_NAME}-openbao/offsite.env`: can't read/list/delete). To restore after losing the Mac: download a `.snap` with an admin key, start a fresh OpenBao with the same `seal.key` (from `seal.key.sops`), `bao operator raft snapshot restore -force <file>` |

## Who can do what

| Identity | Login | Access |
|---|---|---|
| `owner` | userpass, UI or `bao login -method=userpass username=owner` | everything (`policies/admin.hcl`) |
| `claude` (automation) | AppRole, `~/${ANVIL_NAME}-openbao/claude.approle` (role_id + secret_id) | **read-only `secret/ops/*`** (`policies/claude-ops.hcl`); 1 h tokens |
| backup | periodic token | Raft snapshots only |

Folders: `secret/ops/…` (what Claude may read to fix ${ANVIL_NAME}), `secret/personal/…` (yours only). Access is by path
(folder), not tags: give a new person a policy for their folders (`bao policy write <name> -` then
`bao write auth/userpass/users/<name> password=… token_policies=<name>`).

## Use

- UI: open the URL, method **Username**, `owner`.
- CLI from any tailnet machine: install `bao` (or use `docker exec -it ${ANVIL_NAME}-openbao bao` on the Mac), then
  `export BAO_ADDR=https://${ANVIL_HOME_TAILNET_HOST}:${ANVIL_HOME_BAO_PORT}; bao login -method=userpass username=owner`;
  `bao kv put secret/ops/<name> key=value`, `bao kv get secret/ops/<name>`, `bao kv list secret/ops`.
- Claude: `bao write auth/approle/login role_id=… secret_id=…` → token (1 h) → `bao kv get secret/ops/…`.
- Export everything (plaintext JSON, one object per secret): `BAO_TOKEN=<admin token> ~/${ANVIL_NAME}-openbao/export.sh > x` and
  protect `x` (e.g. `| age -r <recipient> > x.age`).

## Update

Bump the image tag in `docker-compose.yml` here, copy to `~/${ANVIL_NAME}-openbao/`, `docker compose up -d` on the Mac. It unseals
itself. Take a snapshot first (`~/${ANVIL_NAME}-openbao/backup.sh`).
