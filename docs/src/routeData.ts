// Starlight route middleware (astro.config.mjs routeMiddleware): hero action links written relative in frontmatter
// (index.mdx: `link: overview`) are made absolute under the base path, without a trailing slash. Pages are served
// without one (trailingSlash: 'never'), so on the home page (<base>, not <base>/) a relative link would resolve
// outside the base. Absolute and external links are left alone.
import { defineRouteMiddleware } from '@astrojs/starlight/route-data'

const base = import.meta.env.BASE_URL.replace(/\/+$/, '') // "/anvil", or "" at the root

export const onRequest = defineRouteMiddleware((context) => {
  const hero = context.locals.starlightRoute.entry.data.hero
  for (const action of hero?.actions ?? []) {
    if (/^(?:[a-z][a-z0-9+.-]*:|\/|#)/i.test(action.link)) continue
    action.link = `${base}/${action.link}`.replace(/(.)\/+(?=$|[?#])/, '$1')
  }
})
