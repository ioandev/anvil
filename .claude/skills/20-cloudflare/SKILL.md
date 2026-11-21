---
name: 20-cloudflare
description: Third anvil bootstrap step. Creates the Cloudflare zone for ANVIL_DOMAIN with SSL Full (strict) and our own Authenticated Origin Pulls cert, switches the nameservers (Namecheap API when its token is given, otherwise a HUMAN.md task), waits for activation and the edge certificate, and issues the Origin CA certificate. Use after 10-secrets.
---

# 20-cloudflare: the zone, nameservers, certificates

1. `python3 -I scripts/cloudflare-zones.py`: creates the zone (if missing), mirrors existing DNS records
   (sites.yaml `zones:` → `records:`) DNS-only, sets SSL **Full (strict)**, uploads our origin-pull client cert and
   turns Authenticated Origin Pulls on. Idempotent.
2. Record the zone id: `scripts/anvil-secrets set ANVIL_CF_ZONE_ID=<id>` (from `GET /zones?name=$ANVIL_DOMAIN`).
3. **Nameservers.** Read the pair Cloudflare assigned **to this zone** (`GET /zones/<id>` → `name_servers`; they
   differ per zone, never assume).
   - Namecheap credentials in anvil.env → `namecheap.domains.dns.setCustom` with that pair (show the owner the call
     first; the permission check may block DNS changes: then do the manual path).
   - Otherwise: append to `HUMAN.md` a task with the exact two nameservers and where to set them, and wait for the
     owner.
4. **Wait for activation**: poll `GET /zones/<id>` until `status: active` (minutes to hours). Then wait until
   `GET /zones/<id>/ssl/certificate_packs` has a pack `active`: before that, every HTTPS request through Cloudflare
   fails. Check `https://dns.google/resolve?name=$ANVIL_DOMAIN&type=NS` shows Cloudflare's pair; if Google still
   has the old answer, have the owner flush it at https://developers.google.com/speed/public-dns/cache.
5. `python3 -I scripts/origin-certs.py`: one Origin CA cert per zone (zone + `*.zone`, valid 15 years), stored in
   `.data/origin-ca/`, then `make secrets-encrypt`.

Verify: zone active, edge cert active, `.data/origin-ca/$ANVIL_DOMAIN.crt` exists, AOP enabled
(`GET /zones/<id>/settings/tls_client_auth` → on).
