// /og/<page id>.png for every docs page (see src/og.mjs). The site's title and host go on each card.
import type { APIRoute } from 'astro'
import { getCollection } from 'astro:content'
import { ogPng } from '../../og.mjs'

export async function getStaticPaths() {
  const docs = await getCollection('docs')
  return docs.map((d) => ({ params: { slug: d.id }, props: { title: d.data.title, description: d.data.description || '' } }))
}

export const GET: APIRoute = async ({ props, site }) => {
  const base = import.meta.env.BASE_URL.replace(/\/$/, '')
  const host = site ? new URL(site).host : ''
  const png = await ogPng({ title: props.title, description: props.description, label: `${process.env.ANVIL_DOCS_TITLE || 'anvil'} docs`, footer: `${host}${base}` })
  return new Response(png, { headers: { 'Content-Type': 'image/png' } })
}
