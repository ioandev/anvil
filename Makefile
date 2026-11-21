# anvil: one entry point for the common steps. Settings and secrets come from anvil.env (scripts/anvil-secrets init).
# The bootstrap skills (.claude/skills/00-preflight … 99-teardown) call these targets in order.
-include anvil.env
# anvil.env allows a comment after a value (`ANVIL_REGION=fr-par   # Scaleway region`); make keeps the spaces before
# the `#` as part of the value, so strip every variable the file sets (Terraform rejected "fr-par   " as a region).
$(foreach v,$(shell sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' anvil.env 2>/dev/null),$(eval $(v) := $(strip $($(v)))))
export

# anvil.env -> Terraform variables (infra/variables.tf)
export TF_VAR_name                 = $(ANVIL_NAME)
export TF_VAR_domain               = $(ANVIL_DOMAIN)
export TF_VAR_region               = $(ANVIL_REGION)
export TF_VAR_zone                 = $(ANVIL_ZONE)
export TF_VAR_instance_type        = $(ANVIL_INSTANCE_TYPE)
export TF_VAR_ssh_port             = $(ANVIL_SSH_PORT)
ifneq ($(ANVIL_AGENT_K3S_VERSION),)
export TF_VAR_agent_k3s_version    = $(ANVIL_AGENT_K3S_VERSION)
endif
ifneq ($(ANVIL_SWAP_MB),)
export TF_VAR_swap_size_mb         = $(ANVIL_SWAP_MB)
endif
export TF_VAR_registry_password    = $(SCW_SECRET_KEY)
export TF_VAR_tailscale_auth_key   = $(TAILSCALE_AUTH_KEY)
export TF_VAR_cloudflare_api_token = $(CLOUDFLARE_API_TOKEN)
export TF_VAR_cloudflare_zone_id   = $(ANVIL_CF_ZONE_ID)
export TF_VAR_ssh_public_key_path  = $(SSH_KEY).pub

SSH_KEY := $(HOME)/.ssh/id_ed25519_anvil
TF      := terraform -chdir=infra
APP_IMAGES := anvil-backup=platform/backup twilio-alert=images/twilio-alert anvil-demo=demo webhookd=images/webhookd

.PHONY: help hooks check secrets-encrypt secrets-decrypt ssh-key fetch init plan apply cleanup destroy secrets apps images

help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)

## hooks            enable the git hooks (secrets re-encrypted and sites checked before every commit)
hooks:
	git config core.hooksPath .githooks

## check            sites.yaml vs the manifests, and the secrets' encrypted twins
check:
	python3 -I scripts/sites.py check
	scripts/secrets.sh check

## secrets-encrypt  plaintext secrets -> their .sops twins (only changed files)
secrets-encrypt:
	scripts/secrets.sh encrypt
## secrets-decrypt  .sops twins -> plaintext (fresh clone, after restoring the age key)
secrets-decrypt:
	scripts/secrets.sh decrypt

ssh-key:
	@test -f $(SSH_KEY) && echo "key exists: $(SSH_KEY)" || ssh-keygen -t ed25519 -f $(SSH_KEY) -N "" -C "$(ANVIL_NAME)"

fetch:
	scripts/fetch-image.sh

init:
	$(TF) init

## plan / apply     the server (Terraform in infra/); read the plan before applying
plan: fetch ssh-key
	$(TF) plan $(TFARGS)
apply: fetch ssh-key
	$(TF) apply $(TFARGS)

## cleanup          after the server is up: delete the image-import leftovers (bucket, snapshot, image)
cleanup:
	@echo 'image_pipeline = false' > infra/local.auto.tfvars
	$(TF) apply $(TFARGS)

## destroy          delete the server and everything Terraform made (99-teardown; asks first)
destroy:
	$(TF) destroy

## secrets          build every Kubernetes Secret from anvil.env and apps/*/prod.env
secrets:
	python3 -I scripts/make-secrets.py

## apps             secrets, then deploy every namespace (platform first). Idempotent.
apps: secrets
	scripts/node.sh deploy-all

## images           build and push our images, tagged <YYYYMMDD>-<sha> (multi-arch for the ones the home machine runs)
images:
	scripts/build-images $(APP_IMAGES)
