// The web + API Fastify app. Built by a factory so tests can run it in-process with a MemoryStore.
import Fastify, { LogController } from 'fastify';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { setTimeout as sleep } from 'node:timers/promises';
import { hostname } from 'node:os';
import { Breaker, WEB_MODES, WORKER_MODES } from './breaker.ts';
import type { WebMode } from './breaker.ts';
import { FANOUT_HEADER, forwardToPeers, forwardToWorker, tokenOk } from './admin.ts';
import type { FetchFn, ForwardResult } from './admin.ts';
import { renderPage } from './html.ts';
import type { WebMetrics } from './metrics.ts';
import { RateLimiter, clientIp } from './ratelimit.ts';
import type { Store } from './store.ts';
import { validateEntry } from './validate.ts';

export interface WebAppOptions {
  store: Store;
  metrics: WebMetrics;
  breaker?: Breaker<WebMode>;
  adminToken: string | null;
  rateLimitMax: number;
  rateLimitWindowMs: number;
  slowMs: number;
  port?: number;                   // for peer fan-out
  peersHost?: string | null;
  podIp?: string | null;
  workerAdminUrl?: string | null;
  /** Called by the `crash` mode after the response is sent. */
  exit?: (code: number) => void;
  /** Whether the schema setup finished (readiness waits for it). */
  isReady?: () => boolean;
  fetchFn?: FetchFn;
  resolvePeers?: (host: string) => Promise<string[]>;
  now?: () => number;
  logLevel?: string;
}

const PROBE_PATHS = new Set(['/healthz', '/readyz']);

function pathOf(req: FastifyRequest): string {
  const i = req.url.indexOf('?');
  return i === -1 ? req.url : req.url.slice(0, i);
}

export function buildWebApp(o: WebAppOptions): FastifyInstance & { breaker: Breaker<WebMode>; closing: AbortController } {
  const breaker = o.breaker ?? new Breaker<WebMode>();
  const closing = new AbortController();
  const limiter = new RateLimiter(o.rateLimitMax, o.rateLimitWindowMs, o.now);
  const adminLimiter = new RateLimiter(30, 60_000, o.now); // slows down token guessing
  const podName = process.env.HOSTNAME ?? hostname();
  const exit = o.exit ?? ((code: number) => process.exit(code));
  const isReady = o.isReady ?? (() => true);

  const app = Fastify({
    logger: { level: o.logLevel ?? 'info' },
    logController: new LogController({ disableRequestLogging: true }),
    bodyLimit: 8 * 1024,
    trustProxy: false,          // we read CF-Connecting-IP ourselves (see clientIp)
    forceCloseConnections: 'idle',
    return503OnClosing: true,
  });

  // HTML forms post urlencoded; parse it without an extra dependency.
  app.addContentTypeParser('application/x-www-form-urlencoded', { parseAs: 'string' }, (_req, body, done) => {
    done(null, Object.fromEntries(new URLSearchParams(body as string)));
  });

  // ---- break modes (the admin routes stay reachable so a presenter can always /admin/fix by hand) ----
  app.addHook('onRequest', async (req, reply) => {
    const path = pathOf(req);
    if (path.startsWith('/admin/')) return;
    if (breaker.mode === 'hang') {
      await breaker.wait(); // until /admin/fix, or shutdown
      if (closing.signal.aborted) return reply.code(503).send({ error: 'shutting down' });
    }
    if (breaker.mode === 'slow') {
      await sleep(o.slowMs, undefined, { signal: closing.signal }).catch(() => undefined);
    }
    if (breaker.mode === 'errors' && path !== '/healthz') {
      return reply.code(500).send({ error: 'internal error (demo break mode: errors)' });
    }
  });

  app.addHook('onSend', async (_req, reply, payload) => {
    reply.header('x-content-type-options', 'nosniff');
    reply.header('referrer-policy', 'no-referrer');
    reply.header('content-security-policy',
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
    reply.header('x-served-by', podName);
    return payload;
  });

  app.addHook('onResponse', async (req, reply) => {
    const route = req.routeOptions.url ?? 'unmatched';
    const labels = { method: req.method, route };
    o.metrics.requests.inc({ ...labels, status_code: String(reply.statusCode) });
    o.metrics.duration.observe(labels, reply.elapsedTime / 1000);
    if (!PROBE_PATHS.has(route)) {
      req.log.info({ method: req.method, route, status: reply.statusCode, ms: Math.round(reply.elapsedTime) }, 'request');
    }
  });

  const dbFail = (op: string, req: FastifyRequest, err: unknown) => {
    o.metrics.dbErrors.inc({ op });
    req.log.error({ err, op }, 'database error');
  };

  // ---- probes ----
  app.get('/healthz', async () => ({ status: 'ok' })); // process alive; never touches the database

  app.get('/readyz', async (req, reply) => {
    if (!isReady()) return reply.code(503).send({ status: 'starting', db: 'schema not ready' });
    try {
      await Promise.race([o.store.ping(), sleep(2000).then(() => { throw new Error('ping timeout'); })]);
      return { status: 'ok', db: 'ok' };
    } catch (err) {
      dbFail('ping', req, err);
      return reply.code(503).send({ status: 'unavailable', db: 'unreachable' });
    }
  });

  // ---- pages and API ----
  async function page(reply: FastifyReply, req: FastifyRequest, status: number, extra: Partial<Parameters<typeof renderPage>[0]> = {}) {
    try {
      const [entries, stats] = await Promise.all([o.store.latestEntries(20), o.store.stats()]);
      return reply.code(status).type('text/html; charset=utf-8').send(renderPage({ entries, stats, podName, ...extra }));
    } catch (err) {
      dbFail('page', req, err);
      return reply.code(503).type('text/html; charset=utf-8')
        .send('<!doctype html><title>anvil demo</title><h1>Database unavailable</h1><p>Try again in a moment.</p>');
    }
  }

  app.get('/', async (req, reply) => {
    const posted = (req.query as Record<string, string | undefined>).posted === '1';
    return page(reply, req, 200, posted ? { notice: 'Thanks! Your entry is waiting for the worker to approve it.' } : {});
  });

  app.get('/api/entries', async (req, reply) => {
    const raw = Number((req.query as Record<string, string | undefined>).limit ?? 20);
    const limit = Number.isInteger(raw) ? Math.min(100, Math.max(1, raw)) : 20;
    try {
      return { entries: await o.store.latestEntries(limit) };
    } catch (err) {
      dbFail('list', req, err);
      return reply.code(503).send({ error: 'database unavailable' });
    }
  });

  app.post('/api/entries', async (req, reply) => {
    const isForm = (req.headers['content-type'] ?? '').startsWith('application/x-www-form-urlencoded');
    const rl = limiter.hit(clientIp(req.headers, req.socket.remoteAddress));
    if (!rl.allowed) {
      o.metrics.rateLimited.inc();
      reply.header('retry-after', String(rl.retryAfterSeconds));
      if (isForm) return reply.code(429).type('text/plain; charset=utf-8').send(`Slow down: try again in ${rl.retryAfterSeconds} s.`);
      return reply.code(429).send({ error: 'too many requests', retryAfterSeconds: rl.retryAfterSeconds });
    }
    const v = validateEntry(req.body);
    if (!v.ok) {
      if (isForm) {
        const b = (req.body ?? {}) as Record<string, unknown>;
        return page(reply, req, 400, {
          errors: v.errors,
          form: { name: typeof b.name === 'string' ? b.name : '', message: typeof b.message === 'string' ? b.message : '' },
        });
      }
      return reply.code(400).send({ error: 'invalid entry', fields: v.errors });
    }
    try {
      const entry = await o.store.addEntry(v.value.name, v.value.message);
      o.metrics.entriesCreated.inc();
      if (isForm) return reply.code(303).header('location', '/?posted=1').send();
      return reply.code(201).send({ entry });
    } catch (err) {
      dbFail('insert', req, err);
      return reply.code(503).send({ error: 'database unavailable' });
    }
  });

  // ---- admin: the live-demo break switch ----
  function admin(req: FastifyRequest, reply: FastifyReply): boolean {
    if (!o.adminToken) { reply.code(404).send({ error: 'not found' }); return false; } // disabled without ADMIN_TOKEN
    if (!adminLimiter.hit(clientIp(req.headers, req.socket.remoteAddress)).allowed) {
      reply.code(429).send({ error: 'too many requests' }); return false;
    }
    if (!tokenOk(o.adminToken, req.headers['x-admin-token'])) { reply.code(401).send({ error: 'bad or missing X-Admin-Token' }); return false; }
    return true;
  }

  const fromPeer = (req: FastifyRequest) => req.headers[FANOUT_HEADER] === '1';
  const peers = (path: string, body: unknown): Promise<ForwardResult[]> =>
    o.peersHost && o.port
      ? forwardToPeers({ host: o.peersHost, port: o.port, selfIp: o.podIp ?? null, resolve: o.resolvePeers, fetchFn: o.fetchFn }, path, o.adminToken!, body)
      : Promise.resolve([]);

  function setMode(mode: WebMode | null) {
    if (mode) breaker.set(mode); else breaker.clear();
    for (const m of WEB_MODES) o.metrics.breakMode.set({ mode: m }, m === mode ? 1 : 0);
  }

  app.post('/admin/break', async (req, reply) => {
    if (!admin(req, reply)) return reply;
    const body = (req.body ?? {}) as { mode?: unknown; all?: unknown };
    const mode = body.mode;
    if ((WORKER_MODES as readonly unknown[]).includes(mode)) {
      if (!o.workerAdminUrl) return reply.code(400).send({ error: 'WORKER_ADMIN_URL not set: break the worker on its own port' });
      const worker = await forwardToWorker(o.workerAdminUrl, '/admin/break', o.adminToken!, { mode }, o.fetchFn);
      return reply.code(worker.status === 200 ? 200 : 502).send({ ok: worker.status === 200, mode, worker });
    }
    if (!(WEB_MODES as readonly unknown[]).includes(mode)) {
      return reply.code(400).send({ error: `mode must be one of: ${[...WEB_MODES, ...WORKER_MODES].join(', ')}` });
    }
    const webMode = mode as WebMode;
    // Tell the other pods first (crash would otherwise take us down before they hear about it).
    const peerResults = body.all === false || fromPeer(req) ? [] : await peers('/admin/break', { mode: webMode, all: false });
    req.log.warn({ mode: webMode }, 'BREAK MODE ON (demo)');
    if (webMode === 'crash') {
      reply.raw.once('finish', () => { req.log.fatal('crash mode: exiting with status 1 (demo)'); exit(1); });
    } else {
      setMode(webMode);
    }
    return reply.send({ ok: true, mode: webMode, pod: podName, peers: peerResults });
  });

  app.post('/admin/fix', async (req, reply) => {
    if (!admin(req, reply)) return reply;
    setMode(null);
    req.log.warn('break mode cleared (demo)');
    if (fromPeer(req)) return reply.send({ ok: true, pod: podName });
    const [peerResults, worker] = await Promise.all([
      peers('/admin/fix', {}),
      o.workerAdminUrl ? forwardToWorker(o.workerAdminUrl, '/admin/fix', o.adminToken!, {}, o.fetchFn) : Promise.resolve(null),
    ]);
    return reply.send({ ok: true, pod: podName, peers: peerResults, worker });
  });

  // On shutdown: let parked (hang) and sleeping (slow) requests finish so close() doesn't wait for them.
  app.addHook('preClose', async () => {
    closing.abort();
    breaker.releaseAll();
  });

  return Object.assign(app, { breaker, closing });
}
