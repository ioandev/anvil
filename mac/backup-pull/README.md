# backup-pull: a local copy of the server's databases

`pull.sh` keeps a copy of the server's databases on whichever machine runs it (Linux or macOS), **encrypted**, checked and rotated, once a day. Settings are in `.env` next to it (`.env.example` explains every line). `install.sh` schedules it.

## Two sources

| `SOURCE=` | What you get | What it needs | Where it's safe |
|---|---|---|---|
| `bucket` | the nightly off-site backups, copied from the bucket: every atlas database and any other nightly backup (SQLite files), as they were last night | a key that can only **read and list** the bucket (Scaleway IAM: ObjectStorageObjectsRead + ObjectStorageBucketsRead, no expiry) | any machine: the key can't change or delete anything |
| `live` | a fresh dump of every atlas database **right now** (the same `mariadb-dump` options as the nightly job), as the read-only `atlas_backup` user | the server's SSH key and `ATLAS_BACKUP_PASSWORD` | only machines you'd trust with the SSH key, which is root on the server |
| `both` | live, then bucket | both | |

`live` covers atlas only (on the original server: 12 databases, about 8.5 MB gzipped, 20 seconds). `bucket` also has the other nightly backups (SQLite files), and keeps working if the server is down.

## Encrypted: nothing in plaintext, and the backup machine can't read its own copies

The dumps hold every site's users (emails, password hashes), so every file is encrypted with [age](https://age-encryption.org) to `AGE_RECIPIENT`, the **public** half of the same age key that protects this repo's secrets (`.sops.yaml`), while it streams in. No plaintext copy is ever written to disk, and the dump check happens on the stream too. The backup machine holds only the public key, so a stolen laptop or a synced copy of the folder reveals nothing. Only the private key can decrypt: `~/.config/sops/age/keys.txt` on the operator's machine, plus the copy in your password manager. Never put that key on a backup machine. Disk encryption (FileVault, LUKS) is still worth having on top.

## Where the copies go

```
~/<name>-backups/              (DEST in .env)
  live/<UTC time>/<database>.sql.gz.age     kept LIVE_KEEP_DAYS (30)
  daily/<date>/<source>/<file>.age          kept DAILY_KEEP_DAYS (90, at least 31; the bucket itself keeps 30)
  monthly/<YYYY-MM>/<source>/<file>.age     kept forever
  .last-pull-ok                             time of the last good run
```

Each dump is checked as it streams: the gzip must be intact and end with mariadb-dump's `-- Dump completed` line, so a cut-off file is rejected and nothing of it is kept. A live run writes into `<time>.part` and only renames it when every database checked out. The bucket mode fetches only files this machine doesn't have yet, one at a time (`rclone cat`, straight into age), so the read-only key is enough.

## Set up a machine

```sh
cp .env.example .env && chmod 600 .env    # then fill it in: SOURCE and the keys for it (AGE_RECIPIENT is preset)
./pull.sh && tail pull.log                # one run by hand
./install.sh                              # schedule it
```

`install.sh` checks every hour and runs once a day (`pull.sh --daily`), so a PC that was switched off catches up when it's back on:

- **Linux**: a systemd user timer `<name>-backup-pull.timer`, with `loginctl enable-linger` so it runs without you logged in (`systemctl --user list-timers`). Without systemd: a crontab line.
- **macOS**: a launchd agent `com.anvil.<name>-backup-pull`.
- `./install.sh remove` undoes it.

A failure is logged in `pull.log` and, when `WEBHOOK_TOKEN` is set, posts one line to the server's error list (`STATUS_URL/error_arduino`, when `STATUS_URL` is set too).

## Where it runs

Any machine with the `.env` filled in: the home machine (`scripts/home-deploy backup-pull`, then write its `.env` and
run `~/${ANVIL_NAME}-backup-pull/install.sh` there) with `SOURCE=bucket`, or the operator's own machine with `SOURCE=live`. Never
copy the SSH key, the database password or the age private key to a machine that only needs `bucket`.

## Restore one database from a copy

On the operator's machine (the private key is there):

```sh
age -d -i ~/.config/sops/age/keys.txt -o /repos/_data/<ns>/db.sql.gz ~/<name>-backups/live/<time>/<db>.sql.gz.age
#   or a daily/<date>/mariadb/<db>.sql.gz.age from a bucket copy
scripts/node.sh restore-db <ns>
```

From another machine's copy: bring the `.age` file to the operator's machine first, or decrypt it with the key from your password manager on a machine you trust, then delete the plaintext.

This replaces only that database (CLAUDE.md). The dumps contain `CREATE DATABASE`/`USE`, as `restore-db` needs.
