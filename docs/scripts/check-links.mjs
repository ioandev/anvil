// Post-build link check: every internal href/src in dist/ must point at a file the build produced, under the
// configured base path, and every #fragment must exist on the target page. Exits 1 on any problem, so
// `npm run build` fails on a broken link. No dependencies.
import { readdirSync, readFileSync, existsSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const dist = new URL('../dist/', import.meta.url).pathname
const rawBase = process.env.ASTRO_BASE || '/anvil'
const base = ('/' + rawBase.replace(/^\/+|\/+$/g, '')).replace(/^\/$/, '')

const htmlFiles = []
const walk = (d) => {
  for (const e of readdirSync(d)) {
    const p = join(d, e)
    if (statSync(p).isDirectory()) walk(p)
    else if (p.endsWith('.html')) htmlFiles.push(p)
  }
}
if (!existsSync(dist)) {
  console.error('check-links: dist/ not found, run astro build first')
  process.exit(1)
}
walk(dist)

const idCache = new Map()
const idsOf = (file) => {
  if (!idCache.has(file)) {
    const html = readFileSync(file, 'utf8')
    idCache.set(file, new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])))
  }
  return idCache.get(file)
}
const resolveFile = (path) => {
  const rel = decodeURIComponent(path.slice(base.length)).replace(/^\/+/, '')
  const candidates = rel === '' || rel.endsWith('/') ? [join(dist, rel, 'index.html')] : [join(dist, rel), join(dist, rel, 'index.html'), join(dist, rel + '.html')]
  return candidates.find((c) => existsSync(c) && statSync(c).isFile())
}

const problems = []
let checked = 0
for (const file of htmlFiles) {
  const html = readFileSync(file, 'utf8')
  for (const m of html.matchAll(/\s(?:href|src)="([^"]*)"/g)) {
    const url = m[1].replace(/&amp;/g, '&')
    if (!url || /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(url)) continue // external, mailto:, data:, …
    const where = relative(dist, file)
    if (url.startsWith('#')) {
      const id = decodeURIComponent(url.slice(1))
      if (id && !idsOf(file).has(id)) problems.push(`${where}: missing anchor ${url}`)
      checked++
      continue
    }
    if (!url.startsWith('/')) continue // relative links: resolved by the browser, rare here (hero actions); skip
    checked++
    const [pathAndQuery, frag] = url.split('#')
    const path = pathAndQuery.split('?')[0]
    if (base && path !== base && !path.startsWith(base + '/')) {
      problems.push(`${where}: link outside the base path ${base}: ${url}`)
      continue
    }
    const target = resolveFile(path)
    if (!target) {
      problems.push(`${where}: broken link ${url}`)
      continue
    }
    if (frag && target.endsWith('.html') && !idsOf(target).has(decodeURIComponent(frag))) {
      problems.push(`${where}: missing anchor ${url}`)
    }
  }
}

if (problems.length) {
  console.error(`check-links: ${problems.length} problem(s) in ${htmlFiles.length} pages:`)
  for (const p of [...new Set(problems)]) console.error('  ' + p)
  process.exit(1)
}
console.log(`check-links: ${checked} internal links in ${htmlFiles.length} pages, all OK (base "${base || '/'}")`)
