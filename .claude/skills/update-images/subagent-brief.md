# Brief: update one repo's packages, rebuild and publish its images

You update **one** repo (its entry from `repos.yaml` is below this brief). You update its packages to the latest
versions, make sure it still builds and its tests pass, build its images and push them to the registry. **You never
deploy, restart or touch anything in production**, and you never change the repo's `main`/current branch.

## Hard rules

- Work only in a fresh git worktree in the scratchpad, on a new branch `deps/<YYYY-MM-DD>` made from the repo's
  current `HEAD` commit. Never edit the repo's own working tree (it often has the owner's uncommitted work), never
  commit to its current branch, never `git push`, never merge.
- No production access: no `kubectl`, no `scripts/node.sh`, no SSH to the platform or the home machine, no real databases, no
  emails, no phone calls, no Discord/Telegram logins with real tokens. Tests that need a DB get a throwaway local one.
- Never print or copy secrets (`.env`, `prod.env`, tokens). The only secret you use is `SCW_SECRET_KEY` from
  `.env`, for `podman login` (pipe it, don't echo it).
- Keep each file's line endings and style. Don't reformat or refactor beyond what an upgrade needs.
- Disk is limited: `df -h /home /tmp` before building; remove your worktree and local images when done.

## Steps

1. **Worktree:** `git -C <path> worktree add -b deps/<date> <scratchpad>/upd-<repo> HEAD`. If the repo has submodules,
   `git submodule update --init` in it. Note `git -C <path> status --short`: if the owner's working tree has
   uncommitted changes, the build you make won't include them. Say so in the report (and whether the live image
   seems to include them, per the `notes`).
2. **Update packages to latest**, in every part that one of the listed images builds:
   - npm: `npx -y npm-check-updates -u` then `npm install` (keep the lockfile type the repo uses: pnpm/yarn likewise).
   - Gradle: bump versions in `gradle/libs.versions.toml` / `build.gradle(.kts)` and the wrapper
     (`./gradlew wrapper --gradle-version <latest>`); for Spring Boot apps update the Boot plugin and let its BOM
     manage the rest.
   - Python: latest versions in `requirements.txt` / `pyproject.toml`.
   - Go: `go get -u ./... && go mod tidy`; Go isn't installed here, so run it in a container
     (`podman run --rm -v <worktree>:/src:Z -w /src docker.io/library/golang:<latest> …`). The same trick works for
     any missing toolchain.
   - **Dockerfile base images:** latest of the same flavour (`node:24-alpine` → newest Node LTS alpine, etc.). Keep the
     `USER`/uid lines as they are.
   - **Major versions:** go to latest. If a major breaks the build or tests, fix it when the fix is small and clear
     (renamed import, changed config key, per the package's migration guide). If it isn't, hold that one package at
     the newest version that works and list it in the report. Don't spend an hour on one package.
3. **Check:** run the repo's build, lint/typecheck and tests (see its CLAUDE.md, README, justfile, Makefile,
   package.json scripts). Everything that passed before your changes must pass after. If a test was already failing
   on `HEAD` before your changes, say so (check with `git stash` or a second worktree) instead of fixing unrelated code.
4. **Commit** on `deps/<date>`: one commit, message `deps: update packages to latest (<date>)` plus a short list of the
   majors. End it with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
5. **Build and push** every image in the entry, with the context/dockerfile/args/target given there:
   - Tag `<YYYYMMDD>-<short sha of your commit>` (UTC date; `scripts/image-tag <repo dir>` prints it after you commit), pushed to `$ANVIL_REGISTRY/<name>:<tag>`.
   - Single platform (default): `podman build --platform linux/amd64 -t <ref> …` then `podman push <ref>`.
   - `platforms: [linux/amd64, linux/arm64]`: build each platform under `<ref>-amd64` / `<ref>-arm64`, then
     `podman manifest create <ref>-multi`, `podman manifest add` both (`containers-storage:` refs),
     `podman manifest push --all <ref>-multi docker://<ref>`. arm64 runs through qemu: slow, give it time.
   - Use `set -euo pipefail` in build scripts, so a failed build never pushes.
   - Check what you pushed: `podman pull <ref>` (or `podman manifest inspect` for multi-arch) succeeds.
6. **Smoke test** each image locally where it's cheap: start it with `podman run --rm` and dummy env, check it starts
   (web apps answer on their port; bots get as far as "no token" without crashing). Stop it after.
7. **Clean up:** `git -C <path> worktree remove --force <worktree>` (the branch stays), `podman rmi` your local
   images and manifests.

## Report (your final message, exactly this shape)

```
REPO: <name>
RESULT: ready | ready-with-risk | failed
BRANCH: deps/<date> @ <short sha> (in <path>)
IMAGES:
  - $ANVIL_REGISTRY/<name>:<tag>  [platforms]  (live now: <old image from the entry>)
PACKAGES (every change, per part/folder; the owner reads these before approving the release):
  <part>: <pkg> <old> → <new> [MAJOR: <breaking changes that matter here, and what you changed for them>]
  ...
  base images: <old> → <new>
MAJOR UPGRADES: <pkg old → new, ...> | none
HELD BACK: <pkg at version, why> | none
TESTS: <what ran: passed / failed (which), and anything already failing on HEAD>
SMOKE TEST: <started ok / what happened>
COMMIT CONTENTS: <besides package files: which code/config you changed and why> | packages only
UNRELEASED COMMITS: <commits on HEAD newer than the live image, if you can tell> | none known
RISKS / NOTES: <uncommitted owner work not included, repo ahead of live, config or env changes the release needs
  (new env vars, changed ports, migrations), anything the main agent must do or check when releasing>
```

`ready-with-risk` when it's built and pushed but something above makes releasing it less than routine. `failed`
when nothing usable was pushed or tests fail; then say exactly where it stopped.
