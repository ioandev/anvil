# anvil docs

The documentation site for anvil: [Astro](https://astro.build) + [Starlight](https://starlight.astro.build), built
to static files and served by an unprivileged nginx. Search is Starlight's built-in Pagefind; diagrams are inline SVG
components (`src/components/`) drawn with Starlight's colour tokens, so they follow the light/dark theme with no
client-side JavaScript.

## Configuration (build time)

| Variable | Default | Meaning |
|---|---|---|
| `ASTRO_BASE` | `/anvil` | URL path the site lives under; `/` for a site at the root of its host |
| `ANVIL_DOCS_SITE` | `https://ioan.dev` | the origin it's served from (canonical URLs, sitemap) |

Both are baked into the build (every link contains the base), so build once per base path.

## Brand (optional)

To make the docs look like the site that hosts them, put a folder at `src/brand/` before building (gitignored; the
build log says `docs: brand overlay "<title>"`):

| File | Meaning |
|---|---|
| `brand.json` | `{ "title": "anvil", "logo": "logo.svg", "replacesTitle": false, "favicon": "/favicon.png", "theme": "dark", "links": [{ "label": "← example.com", "href": "https://example.com/" }] }` (every key optional; `logoLight` + `logoDark` instead of `logo` for one per theme; `theme: "dark"` makes the site dark only, with no theme picker; `favicon` is a path under `public/`, so copy that file there too) |
| `brand.css` | loaded after the docs' own CSS: Starlight's colour tokens (`--sl-color-*`), fonts (self-hosted: the CSP allows `font-src 'self'`) |
| anything else | files `brand.css` or `brand.json` refer to (logo, fonts) |

Without the folder the docs build with anvil's own look.

## Develop

```sh
npm ci
npm run dev                  # http://localhost:4321/anvil/
npm run build                # dist/ + the link check; fails on any broken internal link or anchor
npm run preview              # serve dist/ locally
ASTRO_BASE=/ npm run build   # e.g. for a docs.example.com host
```

Content is in `src/content/docs/` (MDX). Write internal links root-relative **without** the base
(`[Edge](/components/edge/)`): a small remark plugin in `astro.config.mjs` adds the base, and
`scripts/check-links.mjs` (run by `npm run build`) proves every internal link and `#anchor` resolves. The sidebar is
in `astro.config.mjs`. `src/components/` holds the diagram components (`Diagram.astro` and one file per diagram).

## Container

```sh
podman build -t anvil-docs .
podman run --rm -p 8080:8080 --read-only --tmpfs /tmp anvil-docs
curl -I http://localhost:8080/anvil            # 200
curl -s http://localhost:8080/healthz           # ok

podman build --build-arg ASTRO_BASE=/ --build-arg ANVIL_DOCS_SITE=https://docs.example.com -t anvil-docs:root .
```

- Multi-stage: Node.js LTS (24) builds; `nginxinc/nginx-unprivileged` (stable 1.30, alpine) serves.
- Runs as UID/GID `101:101` on port 8080, works with a read-only root filesystem (pid and temp files in `/tmp`, which
  must be writable: a tmpfs, or an `emptyDir` in Kubernetes). On anvil, set the platform's own `runAsUser`/`runAsGroup`
  for it like any other app.
- `nginx.conf` is a template: the Dockerfile fills in the base path. Caching: `/_astro/` one year (fingerprinted),
  Pagefind one hour, HTML always revalidated. Security headers: CSP (self only; `'unsafe-inline'` for Starlight's
  inline theme script, `'wasm-unsafe-eval'` for Pagefind), `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy`,
  `Permissions-Policy`, COOP. TLS and HSTS are the job of what's in front (Cloudflare + Traefik).
- `GET /healthz` answers `ok` for probes.

On anvil it would be served at `https://<your-domain>/anvil` by a path route on an existing host (like any app with a
base path): an Ingress with `path: /anvil`, probes on `/healthz`, and a probe URL in `sites.yaml`.
