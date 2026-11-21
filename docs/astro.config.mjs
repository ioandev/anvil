import { defineConfig } from 'astro/config'
import starlight from '@astrojs/starlight'
import { unified } from '@astrojs/markdown-remark'

// anvil docs: Astro + Starlight, a static build served by nginx (see Dockerfile).
// Both are set at BUILD time (the base path is baked into every link):
//   ASTRO_BASE       URL path the site lives under (default /anvil; "/" for a site at the root)
//   ANVIL_DOCS_SITE  origin it is served from (default https://ioan.dev), used for canonical URLs and the sitemap
const site = process.env.ANVIL_DOCS_SITE || 'https://ioan.dev'
const rawBase = process.env.ASTRO_BASE || '/anvil'
const base = ('/' + rawBase.replace(/^\/+|\/+$/g, '')).replace(/^\/$/, '') // "/anvil" or "" (root)

// Markdown links in the content are written root-relative ("/components/edge/"). Starlight prefixes the base for
// the sidebar, but not for links inside pages, so this remark plugin does it (links, link definitions and the
// href of MDX components such as <LinkCard>). The post-build check (scripts/check-links.mjs) proves none are broken.
function remarkBaseLinks() {
  const fix = (u) =>
    typeof u === 'string' && base && u.startsWith('/') && !u.startsWith('//') && u !== base && !u.startsWith(base + '/')
      ? base + u
      : u
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
  markdown: { processor: unified({ remarkPlugins: [remarkBaseLinks] }) },
  integrations: [
    starlight({
      title: 'anvil',
      description:
        'A reproducible one-server platform: Flatcar + k3s on Scaleway behind Cloudflare, one shared MariaDB, ' +
        'secrets in git, off-site backups, phone alerts and a Claude Code autopilot.',
      favicon: '/favicon.svg',
      logo: { src: './src/assets/logo.svg' },
      customCss: ['./src/styles/custom.css'],
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
