---
name: 70-autopilot
description: Eighth anvil bootstrap step. Installs the autopilot (Claude Code in a container on the home machine) with its own vault, read-only credentials and guardrails, then proves it on the demo app by breaking something and watching it fix it. Use after 60-alerts.
---

# 70-autopilot: Claude fixes what it safely can

1. **Vault on the home machine** (OpenBao, a separate instance from any other): `scripts/home-deploy openbao`, then
   follow `mac/openbao/README.md` (init with a static seal key, the owner's login, the AppRole `claude` with the
   read-only `claude-ops` policy). Put **only operator/troubleshooting credentials** under `secret/ops/`: the
   autopilot's own cluster login (`scripts/node.sh deploy autopilot-access`, then
   `scripts/node.sh autopilot-kubeconfig | bao kv put secret/ops/kube/autopilot kubeconfig=-`), `ops/platform`
   (STATUS_CODE, WEBHOOK_TOKEN, BACKUP_S3_SECRET_KEY for email), the off-site snapshot key. **Never the apps'
   secrets, never the server's SSH key, never the age private key**: the autopilot has no root and can't decrypt
   anything (platform/autopilot-access: what its login may do is enforced by the cluster). Snapshot bucket →
   `ANVIL_OPENBAO_BUCKET`.
2. **The image**: clone https://github.com/ioandev/autopilot and build it there (`REGISTRY=$ANVIL_REGISTRY/autopilot ./build.sh`: amd64 + arm64
   under one tag, pushed), set `ANVIL_AUTOPILOT_TAG` to the tag it prints. A **read-only** deploy key for this repo on GitHub (the autopilot clones it; it can never
   push).
3. The Claude credential goes into the vault, never into a file on the home machine: `ops/autopilot`
   `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) or `ANTHROPIC_API_KEY` (with a spend limit). Then
   `scripts/home-deploy autopilot $ANVIL_REGISTRY/autopilot:$ANVIL_AUTOPILOT_TAG` (renders and ships autopilot.yaml
   too) and `mkdir -p ~/$ANVIL_NAME-autopilot/state ~/$ANVIL_NAME-autopilot-runs` there (mode 700). The AppRole file
   (`~/$ANVIL_NAME-openbao/claude.approle`) is what it logs in with.
4. Check: `https://status.$ANVIL_DOMAIN/autopilot?code=…` shows IDLE with a heartbeat under a minute old.
5. **Live test** (tell the owner first; it may phone them after 5 min if the fix fails):
   - stage a bad release: `scripts/node.sh kubectl -n anvil-demo set env deploy/anvil-demo-web BREAK_ON_START=1`
     (a crash loop), wait. Expected: an alert after ~5-10 min, the autopilot starts, runs `rollout undo`, reports
     FIXED; `/autopilot_runs?code=…` has the whole session.
   - unfixable case: in a throwaway namespace `zz-unfixable`, a Deployment whose `envFrom` names a Secret that
     doesn't exist (CreateContainerConfigError: no restart or rollback can fix it). The autopilot must **give up**
     (it can't create secrets) and the phone calls go on; the reset link re-arms it. Delete the namespace after.
   Clean up every `zz-` thing afterwards.

Verify: both tests behaved; the guard refused anything outside restart/undo/rerun-job/delete-one-pod; and the
cluster refuses it too: `kubectl --as=system:serviceaccount:autopilot-access:autopilot get secrets -A` (as the owner)
is Forbidden, and `... set env deploy/anvil-demo-web X=1 --from=secret/anvil-demo` is refused by the admission policy.
