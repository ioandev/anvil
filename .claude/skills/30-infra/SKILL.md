---
name: 30-infra
description: Fourth anvil bootstrap step. Creates the server with Terraform (Flatcar image import, instance, flexible IP, firewall open only to Cloudflare and SSH on a custom port), waits for SSH and k3s, records the server IP, and switches the image pipeline off. Use after 20-cloudflare.
---

# 30-infra: the server

1. `make init`, then `make plan` and **read the plan with the owner**: expect the image-import chain (bucket, qcow2
   upload, snapshot, image), the private network, the security group (80/443 from Cloudflare's ranges only, the SSH
   port from anywhere), the flexible IP and the instance. Nothing else.
2. `make apply` (first run uploads ~600 MB: a few minutes). If it fails half-way, re-run: it's idempotent.
3. `scripts/anvil-secrets set ANVIL_SERVER_IP=$(terraform -chdir=infra output -raw public_ip)`.
4. Wait for the node: `scripts/node.sh ssh true` (retry up to 10 min), then
   `scripts/node.sh kubectl get nodes` shows `Ready`. First boot installs k3s, Tailscale and swap.
5. Tailscale: the node joined with the auth key. Get its name and IP (`scripts/node.sh ssh tailscale status --self`)
   and `scripts/anvil-secrets set ANVIL_TAILNET_HOST=… ANVIL_TAILNET_IP=…` (one `set` per value).
6. Cleanup: deletes the image-import leftovers (keeps costs down; re-enable before any server rebuild by deleting
   `infra/local.auto.tfvars`). From Claude (no terminal to answer Terraform's prompt): `echo 'image_pipeline = false' >
   infra/local.auto.tfvars`, `make plan TFARGS='-out=cleanup.tfplan'`, check it destroys only the bucket, the qcow2
   object, the snapshot and the image (never the server or its IP), then `make cleanup TFARGS=cleanup.tfplan` and delete
   the plan file. In a terminal, `make cleanup` asks.
7. `make secrets-encrypt` (the Terraform state is a secret: it holds the k3s token).

Verify: `curl -m 5 http://$ANVIL_SERVER_IP` from this machine **fails** (only Cloudflare may connect), SSH works on
`$ANVIL_SSH_PORT`, port 22 is closed, the node is Ready. Never `terraform destroy` here.
