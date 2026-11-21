// Open Graph images: one 1200x630 PNG per page, rendered at build time (satori -> SVG -> resvg -> PNG) and linked from
// every page's <head> (src/components/Head.astro). Colours, fonts and the footer can be set by a brand overlay
// (src/brand/brand.json "og": { background, title, accent, text, muted, label, footer, fontRegular, fontBold }).
import fs from 'node:fs'
import satori from 'satori'
import { Resvg } from '@resvg/resvg-js'

const BRAND = './src/brand'
const brand = fs.existsSync(`${BRAND}/brand.json`) ? JSON.parse(fs.readFileSync(`${BRAND}/brand.json`, 'utf8')) : {}
const o = brand.og || {}
const INTER = './node_modules/@fontsource/inter/files'
const font = (p, fallback) => fs.readFileSync(p ? `${BRAND}/${p}` : fallback)
const FONTS = [
  { name: 'og', data: font(o.fontRegular, `${INTER}/inter-latin-400-normal.woff`), weight: 400, style: 'normal' },
  { name: 'og', data: font(o.fontBold, `${INTER}/inter-latin-700-normal.woff`), weight: 700, style: 'normal' },
]
const C = {
  background: o.background || '#111827',
  title: o.title || '#ffffff',
  accent: o.accent || '#f59e0b',
  text: o.text || '#d1d5db',
  muted: o.muted || '#6b7280',
}

const h = (type, style, ...children) => ({ type, props: { style: { display: 'flex', ...style }, children } })
const clip = (s, n) => (s.length > n ? s.slice(0, n - 1).replace(/\s+\S*$/, '').replace(/[\s,;:.–-]+$/, '') + '…' : s)

export async function ogPng({ title, description, label, footer }) {
  const size = title.length > 34 ? 68 : title.length > 22 ? 84 : 96
  const tree = h('div', { width: '100%', height: '100%', flexDirection: 'column', justifyContent: 'center', padding: 80,
                          background: C.background, color: C.text, fontFamily: 'og', position: 'relative' },
    h('div', { fontSize: 30, fontWeight: 700, color: C.accent, letterSpacing: 1, marginBottom: 24 }, o.label || label),
    h('div', { fontSize: size, fontWeight: 700, color: C.title, lineHeight: 1.1 }, clip(title, 70)),
    h('div', { marginTop: 24, width: 160, height: 8, background: C.accent, borderRadius: 4 }),
    ...(description ? [h('div', { marginTop: 32, fontSize: 34, color: C.text, lineHeight: 1.35 }, clip(description, 150))] : []),
    h('div', { position: 'absolute', bottom: 60, left: 80, fontSize: 28, color: C.muted }, o.footer || footer))
  const svg = await satori(tree, { width: 1200, height: 630, fonts: FONTS })
  return new Resvg(svg, { fitTo: { mode: 'width', value: 1200 } }).render().asPng()
}
