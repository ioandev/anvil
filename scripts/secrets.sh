#!/usr/bin/env bash
# Secrets in git, encrypted with SOPS + age.
#
# Every secret has a plaintext working copy (gitignored, what the scripts read) and an encrypted twin
# "<path>.sops" (committed). Twins of files under the gitignored .data/ live under secrets/.data/.
# The age private key is ~/.config/sops/age/keys.txt; keep its only other copy in your password manager.
#
#   scripts/secrets.sh encrypt   plaintext -> .sops (only files that changed)
#   scripts/secrets.sh decrypt   .sops -> plaintext (fresh machine / after pull)
#   scripts/secrets.sh check     exit 1 if any .sops is stale or a plaintext is tracked
set -euo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

# The list is derived from the layout, so a new app's prod.env or a new zone's cert can't be forgotten.
FILES=(anvil.env infra/terraform.tfstate mac/openbao/seal.key mac/openbao/secrets.env mac/autopilot/secrets.env
       apps/*/prod.env platform/*/prod.env .data/cloudflare-aop/*.key .data/cloudflare-aop/*.crt
       .data/origin-ca/*.key .data/origin-ca/*.crt)
# Also the twins that exist without a plaintext yet (fresh clone: decrypt must find them).
for t in anvil.env.sops infra/terraform.tfstate.sops apps/*/prod.env.sops platform/*/prod.env.sops \
         mac/*/*.sops secrets/.data/*/*.sops; do
  f=${t%.sops}; f=${f#secrets/}
  [[ " ${FILES[*]} " == *" $f "* ]] || FILES+=("$f")
done

twin() { [[ $1 == .data/* ]] && echo "secrets/$1.sops" || echo "$1.sops"; }
# Always binary: byte-exact round trips (sops' dotenv mode rewrites comments, blank lines and quoting).
fmt() { echo binary; }
# Plaintext and twin hold the same content? (decrypt and compare; sops output is non-deterministic)
same() { [[ -f $2 ]] && cmp -s "$1" <(sops decrypt --input-type "$(fmt "$1")" --output-type "$(fmt "$1")" "$2"); }

cmd=${1:?usage: secrets.sh encrypt|decrypt|check}
case "$cmd" in
  encrypt)
    for f in "${FILES[@]}"; do
      [[ -f $f ]] || continue
      # only needed once there is something to encrypt (a fresh clone has no secrets yet)
      [[ -f .sops.yaml ]] || { echo "no .sops.yaml: run scripts/anvil-secrets init first"; exit 1; }
      t=$(twin "$f"); mkdir -p "$(dirname "$t")"
      same "$f" "$t" && continue
      sops encrypt --input-type "$(fmt "$f")" --output-type "$(fmt "$f")" --filename-override "$t" "$f" > "$t.tmp"
      mv "$t.tmp" "$t"; echo "encrypted: $f -> $t"
    done ;;
  decrypt)
    for f in "${FILES[@]}"; do
      t=$(twin "$f"); [[ -f $t ]] || continue
      if [[ -f $f ]] && ! same "$f" "$t"; then
        echo "keep (plaintext differs from $t; run encrypt, or delete it to take the git copy): $f"; continue
      fi
      mkdir -p "$(dirname "$f")"; umask 077
      sops decrypt --input-type "$(fmt "$f")" --output-type "$(fmt "$f")" "$t" > "$f"
      echo "decrypted: $t -> $f"
    done ;;
  check)
    bad=0
    for f in "${FILES[@]}"; do
      ! git ls-files --error-unmatch "$f" >/dev/null 2>&1 || { echo "PLAINTEXT TRACKED: $f"; bad=1; }
      [[ -f $f ]] || continue
      same "$f" "$(twin "$f")" || { echo "stale: $(twin "$f") (run scripts/secrets.sh encrypt)"; bad=1; }
    done
    exit $bad ;;
  *) echo "usage: secrets.sh encrypt|decrypt|check"; exit 1 ;;
esac
