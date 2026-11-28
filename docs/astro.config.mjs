import { defineConfig } from 'astro/config'
import starlight from '@astrojs/starlight'
import { unified } from '@astrojs/markdown-remark'
import fs from 'node:fs'

// anvil docs: Astro + Starlight, a static build served by nginx (see Dockerfile).
// Both are set at BUILD time (the base path is baked into every link):
//   ASTRO_BASE       URL path the site lives under (default /anvil; "/" for a site at the root)
//   ANVIL_DOCS_SITE  origin it is served from (default https://ioan.dev), used for canonical URLs and the sitemap
const site = process.env.ANVIL_DOCS_SITE || 'https://ioan.dev'
const rawBase = process.env.ASTRO_BASE || '/anvil'
// Optional brand overlay (README: Brand): src/brand/ (gitignored, copied in by whoever builds a branded copy) with
// brand.json { title, logo (or logoLight + logoDark), replacesTitle, favicon, theme: "dark" (dark only), links: [{ label, href }] } and brand.css (loaded after ours).
const BRAND = './src/brand'
const brand = fs.existsSync(`${BRAND}/brand.json`) ? JSON.parse(fs.readFileSync(`${BRAND}/brand.json`, 'utf8')) : null
process.env.ANVIL_DOCS_TITLE = brand?.title || 'anvil'
if (brand) console.log(`docs: brand overlay "${brand.title || 'anvil'}"`)
const base = ('/' + rawBase.replace(/^\/+|\/+$/g, '')).replace(/^\/$/, '') // "/anvil" or "" (root)

// Markdown links in the content are written root-relative ("/components/edge/"). Starlight prefixes the base for
// the sidebar, but not for links inside pages, so this remark plugin does it (links, link definitions and the
// href of MDX components such as <LinkCard>). The post-build check (scripts/check-links.mjs) proves none are broken.
function remarkBaseLinks() {
  // No trailing slashes (trailingSlash: 'never' below): "/components/edge/#x" becomes "<base>/components/edge#x".
  const noSlash = (u) => u.replace(/(.)\/+(?=$|[?#])/, '$1')
  const fix = (u) => {
    if (typeof u !== 'string' || !u.startsWith('/') || u.startsWith('//')) return u
    return noSlash(base && u !== base && !u.startsWith(base + '/') ? base + u : u)
  }
  const walk = (node) => {
    if (node.type === 'link' || node.type === 'definition') node.url = fix(node.url)
    if ((node.type === 'mdxJsxFlowElement' || node.type === 'mdxJsxTextElement') && Array.isArray(node.attributes)) {
      for (const a of node.attributes) if (a.name === 'href') a.value = fix(a.value)
    }
    if (Array.isArray(node.children)) node.children.forEach(walk)
  }
  return (tree) => walk(tree)
}

export default defineConfig({
  site,
  base: base || '/',
  // Page URLs never end in a slash (/anvil/architecture, not /anvil/architecture/): links, canonical URLs, the sitemap
  // and search results follow this, and nginx (nginx.conf) redirects a slashed URL to its slash-less form.
  trailingSlash: 'never',
  markdown: { processor: unified({ remarkPlugins: [remarkBaseLinks] }) },
  integrations: [
    starlight({
      title: brand?.title || 'anvil',
      description:
        'A reproducible one-server platform: Flatcar + k3s on Scaleway behind Cloudflare, one shared MariaDB, ' +
        'secrets in git, off-site backups, phone alerts and a Claude Code autopilot.',
      favicon: brand?.favicon || '/favicon.svg',
      logo: brand?.logoLight && brand?.logoDark
        ? { light: `${BRAND}/${brand.logoLight}`, dark: `${BRAND}/${brand.logoDark}`, replacesTitle: !!brand?.replacesTitle }
        : { src: brand?.logo ? `${BRAND}/${brand.logo}` : './src/assets/logo.svg', replacesTitle: !!brand?.replacesTitle },
      customCss: ['./src/styles/custom.css', ...(fs.existsSync(`${BRAND}/brand.css`) ? [`${BRAND}/brand.css`] : [])],
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/ioandev/anvil' }],
      // Hero buttons' relative links (index.mdx: overview, quickstart) become <base>/overview: pages have no trailing
      // slash, so a relative link on the home page would otherwise resolve outside the base.
      routeMiddleware: './src/routeData.ts',
      components: {
        Head: './src/components/Head.astro',   // + each page's Open Graph image (src/og.mjs)
        ...(brand?.links?.length ? { SocialIcons: './src/components/BrandLinks.astro' } : {}),
        ...(brand?.theme === 'dark'
          ? { ThemeProvider: './src/components/BrandDarkTheme.astro', ThemeSelect: './src/components/Empty.astro' }
          : {}),
      },
      head: [{ tag: 'script', content: fs.readFileSync('./src/sidebar-toggles.js', 'utf8') }],   // collapsible sidebars
      lastUpdated: false,
      pagination: true,
      sidebar: [
        { label: 'Overview', slug: 'overview' },
        {
          label: 'Quickstart (about 1 h)',
          items: [
            { label: 'Quickstart', slug: 'quickstart' },
            { label: 'Bootstrap skills', slug: 'quickstart/bootstrap-skills' },
            { label: 'The demo app', slug: 'quickstart/demo-app' },
          ],
        },
        { label: 'Architecture', slug: 'architecture' },
        {
          label: 'Components',
          items: [
            { label: 'Infrastructure', slug: 'components/infrastructure' },
            { label: 'Edge (Cloudflare)', slug: 'components/edge' },
            { label: 'Data & backups', slug: 'components/data' },
            { label: 'Monitoring & phone alerts', slug: 'components/monitoring' },
            { label: 'Status webhooks', slug: 'components/status-webhooks' },
            { label: 'Secrets', slug: 'components/secrets' },
            { label: 'Autopilot', slug: 'components/autopilot' },
            { label: 'Mac helpers', slug: 'components/mac-helpers' },
            { label: 'Claude Code workflow', slug: 'components/claude-code' },
          ],
        },
        {
          label: 'Operations',
          items: [
            { label: 'Deploy an app', slug: 'operations/deploy-app' },
            { label: 'Add a site', slug: 'operations/add-site' },
            { label: 'Restore a database', slug: 'operations/restore-database' },
            { label: 'Rotate a password', slug: 'operations/rotate-password' },
            { label: 'Silence or stop alerts', slug: 'operations/silence-alerts' },
            { label: 'Remove a service', slug: 'operations/remove-service' },
            { label: 'Scale a site out', slug: 'operations/scale-out' },
            { label: 'Load-test a site', slug: 'operations/load-test' },
            { label: 'Rebuild the server', slug: 'operations/rebuild-server' },
          ],
        },
        { label: 'Security', slug: 'security' },
        { label: 'Costs', slug: 'costs' },
        {
          label: 'Decisions',
          items: [
            { label: 'Why decisions are written down', slug: 'decisions' },
            { label: 'Scaleway', slug: 'decisions/scaleway' },
            { label: 'Flatcar + k3s', slug: 'decisions/flatcar-k3s' },
            { label: 'Cloudflare Free + own-CA origin pulls', slug: 'decisions/cloudflare' },
            { label: 'One shared MariaDB', slug: 'decisions/shared-mariadb' },
            { label: 'SOPS in git', slug: 'decisions/sops-in-git' },
            { label: 'Phone calls, not email', slug: 'decisions/phone-calls' },
            { label: 'An autopilot with guardrails', slug: 'decisions/autopilot' },
            { label: 'Labels, not renames', slug: 'decisions/labels-not-renames' },
          ],
        },
        { label: 'Lessons learned', slug: 'lessons' },
        { label: 'History', slug: 'history' },
        {
          label: 'Reference',
          items: [
            { label: 'Variables', slug: 'reference/variables' },
            { label: 'Endpoints', slug: 'reference/endpoints' },
            { label: 'Alert rules', slug: 'reference/alert-rules' },
            { label: 'Rules for every app', slug: 'reference/app-rules' },
            { label: 'sites.yaml format', slug: 'reference/sites-yaml' },
            { label: 'Image tags', slug: 'reference/image-tags' },
          ],
        },
      ],
    }),
  ],
})
