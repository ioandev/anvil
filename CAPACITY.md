# Capacity: what a load test taught us, and what every site needs before it's published

For Claude working on an anvil platform. Read this before publishing a new site, before a launch or a campaign that may bring a crowd, and before changing caching, health checks or server sizes. It comes from a ceiling test of a real anvil-style deployment (9 runs, 2026-11-07/08: a Next.js website, a Rust API and MariaDB behind Cloudflare and Traefik, k6 from a machine in the same region); the numbers are that deployment's, the lessons are general.

## What the test found

In order of what limited the site, as each fix was applied:

1. **A health check turned "slow" into "down"** (the first and most important finding). The website's readiness probe rendered `/` with Kubernetes' default 1-second timeout. Under load the page took longer, Kubernetes marked the only website pod not ready and stopped sending it traffic, and every page answered 503 until the check passed again. Fix: **readiness = a port check** (`tcpSocket`), liveness = the real page with a generous timeout (10 s, 5 failures). After the fix, the same overload produced slow answers and 0 errors.
2. **Rendering pages is the most expensive thing a site does.** One Next.js process tops out at about 1.3 cores; more website pods used more cores, until the server was full. On 8 cores, rendering took 4.9 of them.
3. **A 1-second cache for anonymous pages tripled capacity** on the same server (clean capacity ~900 → ~2,800 requests a second on 8 cores) and kept pages at ~35 ms at any load; the website's CPU fell from 4.9 to 0.5 cores. Caching the public, read-only API the same way added another ~20%.
4. **One database query was most of the database's load**: counting sign-ups per event, without an index that covered it. A covering index cut its time 4.6-fold. Look at the slow-query log under load; don't guess.
5. **Then the router.** Traefik terminating TLS behind Cloudflare became the largest single user (7.6 of 16 cores at ~5,900 requests a second); a shared-CPU server running Traefik for many sites gives out first (~900–1,000 requests a second in total on 4 shared vCPUs losing 16–30% to "steal").
6. **Capacity grows about linearly with cores** once pages are cached (8 cores ≈ 2,800, 16 cores ≈ 5,900 clean requests a second).

**Why requests failed** (in every run, only after the CPU was full and requests had started to queue): the health check above (503s); the router running out of memory holding thousands of waiting requests (502/520-class); Cloudflare and clients giving up on 4–16 s answers (5xx, HTTP/2 stream resets); and, in a test from one machine, the site's own per-IP rate limit (429). **No CPU headroom, no failures** never happened; **headroom = no failures** always held.

## Rules for every site (apply when publishing, and check existing ones)

1. **Readiness is a port check; liveness renders the real page** with a 10 s timeout and 5 failures. Never let a busy pod be taken out of service by a 1-second check.
2. **`preStop` uses Kubernetes' built-in sleep** (`lifecycle: { preStop: { sleep: { seconds: 5 } } }`), not `exec sleep 5`: minimal images (Rust, distroless) have no `sleep` binary, and the hook then fails silently (`FailedPreStopHook`), dropping requests on every rollout.
3. **Rolling updates with `maxSurge: 1, maxUnavailable: 0`** for anything that serves visitors, so a deploy never takes the site down.
4. **Decide the edge cache** for the site: can its pages be shared between anonymous visitors? The safe, generic rule for Cloudflare's free Cache Rules: cache only `GET`/`HEAD` with **no `Cookie` header**, no `Authorization` header, not Next.js navigation (`RSC` header, `_rsc=` query), not `/api` unless explicitly public and read-only, never live paths (websockets, event streams), for a time that fits how often the content changes (seconds for live data, minutes for content sites, an hour for docs). Cloudflare never stores responses that set cookies. Turn on **Tiered Cache** (free) so Cloudflare's locations fetch from one upper tier, not each from the server. Purge the site's zone after deploys and when content changes outside a deploy. A crowd of visitors who come, look and leave is then served by Cloudflare at no cost to the server.
   **Cache resized images and build files separately**, for a day and for every visitor, cookies or not (`/_next/image`, `/_next/static/`, `/_astro/`: hashed or keyed by source, width and quality, so the same for everyone). Next.js' image resizer sends `max-age=60` and a separate URL per screen width. Under the short page rule, a phone kept getting a `MISS` and waited for the server to resize the header again (1.35 s for a blog's header on the original server, 2026-11-08); with the one-day rule it got `HIT` at 0.26 s in every sample. Check what a phone really gets with HIT/MISS sampled over hours from the visitors' Cloudflare location, spaced wider than the cache times so the check doesn't warm the cache itself.
5. **Probes must bypass the cache** (send a cookie, e.g. `Cookie: monitoring=1`), or monitoring measures Cloudflare's copy while the site is down.
6. **Bound the queue**: an `inFlightReq` middleware on the site's routes (just above the concurrency of its clean capacity) answers 503 with `Retry-After` at once beyond it, so overload costs a few visitors a retry instead of everyone a timeout, keeps the router's memory bounded and protects the other sites on the same Traefik.
7. **Give routers and caches enough memory for overload**, and set memory limits from a test, not a guess (a router killed for memory takes every site behind it down).
8. **Alert on capacity before failures**: CPU busy over 65% counting steal for 15 minutes, memory available low, a site's failed requests (5xx/429/408) over 5%, the 95th percentile over 2 s. Errors arrive only after latency has climbed.
9. **Plan the busiest expected minute at about 70% of the clean capacity** of the setup in use.

## Load testing a site

- **Never against production's database.** A copy of the site with its own database filled with generated data that follows the app's rules (accounts with sessions created directly, so logged-in flows need no sign-up or email), production's images, no email sending (no SMTP host), no bots, no integrations, behind a password, noindex, and its own rate limits raised (all k6 traffic comes from one IP).
- **Mute every namespace the test touches, `kube-system` included** (a router restart there during a test phoned the owner once), and stop k6 automatically if any real site's probe fails or slows.
- **A staircase that stops itself** (k6 thresholds with `abortOnFail`: over 5% failed, or the 95th percentile over 3 s): the step where latency climbs is the clean capacity; record per-request data, CPU per component every 10 s, and the database's slow-query log.
- **Change one thing per run** and keep the same staircase, so each change's effect is measurable.
- **Record exact status codes**, and use more than one k6 IP for the very top.

## Money and servers

- **Never create, resize or add a bigger or more expensive server without the owner's confirmation**, stating its size, its hourly price and that **a resize restarts the server** (stop, migrate, start: about a minute; downtime for any site living there). Even an open-ended "get the best results" is not a yes to a bigger server.
- **Every started hour is billed in full**, and a resize starts a new billed hour at the new size. Plan test work in whole hours, keep one session for the day instead of creating the server again, and delete test machines as soon as the last run ends.
- In that test: about €1.90 for nine runs and a rehearsal over ~2 hours of hourly servers, €0.44 of it from two resizes that were not needed.
