---
name: update-images
description: Update every app's packages to latest, rebuild and publish its images (one subagent per repo, never deploying), then release the results to the platform / the home machine. Use when asked to update dependencies, refresh or rebuild all images, or do a security/package sweep across the apps.
---

# Update packages, rebuild and publish every app's images

Three steps: **subagents** update, test, build and push images to the registry (never deploy); **you, the main agent**,
collect their reports into a detailed `UPDATE-CONFIRMATION-<timestamp>.md` and wait for the user's approval; then
you release (deploy) what was approved. The repos and their images are in `repos.yaml` (next to this file); the brief each
subagent gets is `subagent-brief.md`. Repos whose source isn't in `/repos` yet are in `REPOS.md`:
they can't be updated; list them in the final report as skipped.

## 1. Prepare (main agent)

1. Read `repos.yaml`. If the user named some apps, do only those; otherwise all of them. Never build the ones under `excluded:` (their images are built elsewhere, e.g. by GitHub CI): list them in the confirmation file as excluded, with the reason.
2. Check `df -h /home /tmp`: each build can take 2–5 GB. Below 25 GB free, run `podman system prune -f` first (only
   dangling images and build cache; never `-a`, which deletes images other work needs).
3. Log in once: `set -a; . .env; set +a; printf '%s' "$SCW_SECRET_KEY" | podman login
   rg.fr-par.scw.cloud -u nologin --password-stdin`. Never print `.env`.
4. Tags: every image gets `<YYYYMMDD>-<short sha of the new commit>` (today's UTC date; `scripts/image-tag <repo>`
   prints it; uncommitted builds get `-dirty-<HHMMSS>`, which is never released). One convention for every image:
   CLAUDE.md "Image tags".

## 2. Fan out (one subagent per repo)

- Launch subagents with the Agent tool (`general-purpose`), **at most 3 at a time**: this machine has limited RAM and
  disk, and arm64 builds through qemu are slow. Big ones (JVM or large Node builds) not together.
- Each prompt = the full text of `subagent-brief.md` + that repo's entry from `repos.yaml` (verbatim) + the tag
  suffix + the scratchpad directory. Nothing else is needed; don't paste secrets.
- While they run, don't build anything yourself. When one finishes, start the next.

## 3. Collect

Each subagent ends with the report block from the brief. Put them together into one table for the user:

| Repo | Result | Images pushed | Major upgrades | Tests | Risk / notes |

`Result` is `ready`, `ready-with-risk` (built and pushed, but a major upgrade wasn't covered by tests, the repo is
ahead of what runs, or similar) or `failed` (nothing pushed, or pushed but tests fail: never release those).

## 4. Write the confirmation file, then wait (main agent)

**Nothing is released (= deployed = pushed to production) before this file exists and the user has approved it.**
Write `docs/updates/UPDATE-CONFIRMATION-<YYYY-MM-DDTHHMMZ>.md` (UTC time it's written, e.g.
`UPDATE-CONFIRMATION-2026-10-24T0430Z.md`), built from the subagents' reports, with:

1. **Summary:** date, the tags, how many repos were updated / ready / ready-with-risk / failed / skipped (repos.yaml).
2. **What goes out**, one section per app to release:
   - namespace, public hosts, and where it runs (the platform, the home machine);
   - each image: current live tag → new tag, registry move if any (Docker Hub/ghcr.io → `$ANVIL_REGISTRY`);
   - source: repo, branch `deps/<date>`, commit, and what's in the commit besides packages (code fixes for majors);
     whether the owner's uncommitted work is NOT included; commits that were never released before (repo ahead of live);
   - **every package changed**: old → new, majors marked, with the breaking changes that matter for this app;
   - held-back packages and why;
   - base image changes (e.g. `node:22-alpine` → `node:24-alpine`);
   - tests and smoke test results;
   - what the release changes besides images: manifest edits, new env vars, pull secret, migrations that run on
     start, ports;
   - risk, what to watch afterwards, and the exact rollback (the old tag to put back).
3. **Not going out:** failed repos (where they stopped), risky ones the user hasn't decided on, skipped repos.
4. **Release order and plan:** the order (e.g. home-machine images first, low-traffic sites before the big
   ones), the checks after each, and roughly how long each is down (zero for rolling updates; bots and singletons
   restart: a few seconds).

Then give the user the file path and a short summary, and **wait for their explicit go-ahead** (all, or a named
subset). Record the decision at the bottom of the file (`## Decision`, time, what was approved). Don't release
anything not approved, and if the images or plan change afterwards, update the file and ask again.

## 5. Release (main agent, only what was approved)

Per app, in the order the file gives:

1. **Check first** (from CLAUDE.md): no app has unsent email queued (no emails go out during a deploy), nothing else
   deploying the same namespace.
2. **Image tags:** set the new `$ANVIL_REGISTRY/...:<tag>` (or its `ANVIL_*_TAG` in anvil.env) in `apps/<ns>/app.yaml` (and `seed-job.yaml` etc.). If the
   namespace pulled from Docker Hub or ghcr.io before, it now needs the `anvil-registry` pull
   secret: add the namespace to `scripts/make-secrets.py` (`pull_secret(ns, env)`, like quiz/claudefix), add
   `imagePullSecrets: [{ name: anvil-registry }]` to its pods, run `make-secrets.py`.
3. **Deploy:** `scripts/node.sh deploy <ns>`, then `kubectl -n <ns> rollout status` for each Deployment.
   - **Home-machine images** (twilio-alert, autopilot): the home machine has no registry login. Ship the arm64 half with
     `podman pull --platform linux/arm64 <image>` → `podman save | ssh … docker load` (SSH details in CLAUDE.md's Mac
     section), set the tag in its compose file, `docker compose up -d`. The arm64 is part of the pushed tag.
   - **server-backup:** used by CronJobs only: update the tag in every manifest that uses it, then run one backup by
     hand (`kubectl create job --from=cronjob/atlas-backup …`) and check it succeeds.
4. **Verify** each public host through Cloudflare (`curl -s -o /dev/null -w '%{http_code}' https://<host>/`),
   `scripts/node.sh curl <host>` on the box, the pod logs for errors, and `https://status.<domain>/overall?code=…` green.
   Bots: the log shows them logged in. Prometheus: no new alerts firing.
5. **Rollback** if anything is wrong: put the previous tag back in `app.yaml`, deploy, and report it.
6. **Afterwards:** update the image tags in CLAUDE.md / HUMAN.md / READMEs that mention them; the CLAUDE.md sites
   table if anything moved; `make secrets-encrypt` if a secret changed. Commit the platform only if the user asks. The
   repos' `deps/<date>` branches are left for the user to merge (say so; never push or merge them yourself).

## 6. Report

Append the outcome to the confirmation file (`## Result`: released, rolled back, or not, per app, with times), then give the user a short table per app: old tag → new tag, released or not (and why), notable upgrades, anything the user must do
(merge the `deps/<date>` branch, skipped repos from repos.yaml, risks they declined).
