// Server-rendered HTML. Everything user-supplied goes through escapeHtml.
import type { Entry, Stats } from './store.ts';
import { MESSAGE_MAX, NAME_MAX } from './validate.ts';

export function escapeHtml(s: string): string {
  return s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

export interface PageModel {
  entries: Entry[];
  stats: Stats;
  podName: string;
  notice?: string;
  errors?: Partial<Record<'name' | 'message', string>>;
  form?: { name?: string; message?: string };
}

const CSS = `
:root{--bg:#f6f4ef;--card:#fff;--ink:#1d1b18;--muted:#6b665d;--accent:#c2410c;--ok:#15803d;--warn:#b45309;--line:#e4dfd5}
@media (prefers-color-scheme:dark){:root{--bg:#171512;--card:#211f1b;--ink:#f3efe7;--muted:#a59f93;--accent:#fb923c;--ok:#4ade80;--warn:#fbbf24;--line:#35312b}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:20px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:52rem;margin:0 auto;padding:2rem 1rem 4rem}
h1{font-size:2.6rem;margin:0 0 .25rem;letter-spacing:-.02em}h1 span{color:var(--accent)}
.sub{color:var(--muted);margin:0 0 1.5rem}
.stats{display:flex;gap:1rem;flex-wrap:wrap;margin:0 0 1.5rem}
.stat{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:.6rem 1rem;min-width:9rem}
.stat b{display:block;font-size:1.8rem;line-height:1.1}.stat small{color:var(--muted)}
form{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:1rem;display:grid;gap:.6rem;margin-bottom:2rem}
input,textarea{font:inherit;padding:.5rem .7rem;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--ink);width:100%}
textarea{min-height:4.5rem;resize:vertical}
button{font:inherit;font-weight:600;padding:.55rem 1.2rem;border:0;border-radius:8px;background:var(--accent);color:#fff;cursor:pointer;justify-self:start}
.err{color:var(--accent);font-size:.85em}.notice{color:var(--ok);font-weight:600}
ul{list-style:none;padding:0;margin:0;display:grid;gap:.75rem}
li{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:.75rem 1rem}
li .meta{color:var(--muted);font-size:.8em;display:flex;gap:.6rem;align-items:center;flex-wrap:wrap}
li p{margin:.25rem 0 0;white-space:pre-wrap;overflow-wrap:anywhere}
.badge{font-size:.75em;font-weight:700;padding:.05rem .5rem;border-radius:99px;border:1px solid currentColor}
.badge.ok{color:var(--ok)}.badge.pending{color:var(--warn)}
footer{margin-top:2rem;color:var(--muted);font-size:.8em}
`;

function fmtTime(d: Date): string {
  return d.toISOString().replace('T', ' ').slice(0, 19) + ' UTC';
}

export function renderPage(m: PageModel): string {
  const items = m.entries.length
    ? m.entries.map((e) => `<li>
  <div class="meta"><strong>${escapeHtml(e.name)}</strong><time datetime="${e.createdAt.toISOString()}">${fmtTime(e.createdAt)}</time>
  ${e.approved ? '<span class="badge ok">approved</span>' : '<span class="badge pending">pending</span>'}</div>
  <p>${escapeHtml(e.message)}</p>
</li>`).join('\n')
    : '<li><p>No entries yet. Be the first!</p></li>';
  const err = (f: 'name' | 'message') => (m.errors?.[f] ? `<span class="err">${escapeHtml(m.errors[f]!)}</span>` : '');
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>anvil demo guestbook</title>
<style>${CSS}</style>
</head>
<body>
<main>
<h1><span>anvil</span> guestbook</h1>
<p class="sub">A tiny app on a single-server Kubernetes platform. Sign it, then watch someone break it.</p>
<div class="stats">
  <div class="stat"><b>${m.stats.total}</b><small>entries</small></div>
  <div class="stat"><b>${m.stats.pending}</b><small>waiting for the worker</small></div>
  <div class="stat"><b>${m.stats.today}</b><small>approved today</small></div>
</div>
${m.notice ? `<p class="notice">${escapeHtml(m.notice)}</p>` : ''}
<form method="post" action="/api/entries">
  <label>Name ${err('name')}<input name="name" maxlength="${NAME_MAX}" required value="${escapeHtml(m.form?.name ?? '')}"></label>
  <label>Message ${err('message')}<textarea name="message" maxlength="${MESSAGE_MAX}" required>${escapeHtml(m.form?.message ?? '')}</textarea></label>
  <button type="submit">Sign the guestbook</button>
</form>
<ul>
${items}
</ul>
<footer>Served by pod <code>${escapeHtml(m.podName)}</code></footer>
</main>
</body>
</html>`;
}
