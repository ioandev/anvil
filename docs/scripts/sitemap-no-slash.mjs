// Post-build: the sitemap lists the docs' home as <site><base>/ even with trailingSlash: 'never' (an @astrojs/sitemap
// quirk); every other URL, the canonical tags and the links already have no trailing slash. Rewrite that one entry to
// <site><base>. A site at the root keeps "/" (a homepage is the one URL that ends in a slash). No dependencies.
import { readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'

const dist = new URL('../dist/', import.meta.url).pathname
const site = (process.env.ANVIL_DOCS_SITE || 'https://ioan.dev').replace(/\/+$/, '')
const base = ('/' + (process.env.ASTRO_BASE || '/anvil').replace(/^\/+|\/+$/g, '')).replace(/^\/$/, '')
if (base && existsSync(dist)) {
  for (const f of readdirSync(dist).filter((f) => /^sitemap-\d+\.xml$/.test(f))) {
    const xml = readFileSync(dist + f, 'utf8')
    const fixed = xml.replaceAll(`<loc>${site}${base}/</loc>`, `<loc>${site}${base}</loc>`)
    if (fixed !== xml) writeFileSync(dist + f, fixed)
  }
}
