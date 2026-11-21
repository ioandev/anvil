---
name: 99-teardown
description: Removes an anvil platform completely (server, IP, buckets, registry images, DNS records, optionally the Cloudflare zone) and verifies nothing billable is left. Only when the owner explicitly asks to tear down; it asks again before deleting.
---

# 99-teardown: delete everything, leave nothing billable

**Ask the owner to confirm, by name of the platform (`$ANVIL_NAME`), before any delete.** Then:

1. DNS: delete the records `cutover.py` created (demo., status., www.) in the zone. Ask whether to delete the zone
   itself (they may want to keep the domain on Cloudflare).
2. `make destroy` (Terraform): instance, IP, private network, security group, image chain if present. Read the plan
   it prints; it must only list this platform's resources.
3. Buckets: the backup bucket and the OpenBao snapshot bucket: ask, because **they hold the only off-site
   copies**. If yes, empty and delete them (with an admin key: the server's key can't delete, by design).
4. Registry namespace `$ANVIL_REGISTRY` (all images), the IAM application `$ANVIL_NAME-backup` and its key.
5. Home machine: `docker compose down` in `~/$ANVIL_NAME-watchdog`, `~/$ANVIL_NAME-autopilot`, `~/$ANVIL_NAME-openbao` (ask before deleting their data).
6. Tailscale: remove the server's node from the tailnet (admin console or API).
7. Verify: Scaleway lists no instance, IP, volume, snapshot, image, bucket or registry namespace named
   `$ANVIL_NAME*` in the project; print the remaining hourly cost (should be €0).

Keep `anvil.env` and the git repo (encrypted twins): with them the platform can be rebuilt.
