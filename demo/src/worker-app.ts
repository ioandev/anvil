// The queue worker: approves new entries and counts them per day, every few seconds. Its HTTP port serves only
// probes, metrics and the admin switch (never exposed publicly).
import Fastify, { LogController } from 'fastify';
import type { FastifyBaseLogger, FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { setTimeout as sleep } from 'node:timers/promises';
import { Breaker, WORKER_MODES } from './breaker.ts';
import type { WorkerMode } from './breaker.ts';
import { tokenOk } from './admin.ts';
import type { WorkerMetrics } from './metrics.ts';
import { RateLimiter, clientIp } from './ratelimit.ts';
import type { Store } from './store.ts';

export class QueueWorker {
  private timer: NodeJS.Timeout | null = null;
  private running: Promise<void> | null = null;
  private stopped = false;
  private store: Store;
  private metrics: WorkerMetrics;
  private breaker: Breaker<WorkerMode>;
  private intervalMs: number;
  private batch: number;
  private log: Pick<FastifyBaseLogger, 'info' | 'error' | 'warn'>;

  constructor(o: { store: Store; metrics: WorkerMetrics; breaker: Breaker<WorkerMode>; intervalMs: number; batch?: number;
    log: Pick<FastifyBaseLogger, 'info' | 'error' | 'warn'> }) {
    this.store = o.store;
    this.metrics = o.metrics;
    this.breaker = o.breaker;
    this.intervalMs = o.intervalMs;
    this.batch = o.batch ?? 100;
    this.log = o.log;
  }

  start(): void {
    this.stopped = false;
    const loop = async () => {
      this.running = this.tick();
      await this.running;
      this.running = null;
      if (!this.stopped) this.timer = setTimeout(loop, this.intervalMs);
    };
    void loop();
  }

  /** One run. In `stuck` mode it does nothing, so the heartbeat goes stale while /healthz stays green. */
  async tick(): Promise<void> {
    if (this.breaker.mode === 'stuck') return;
    try {
      const n = await this.store.processQueue(this.batch);
      if (n > 0) {
        this.metrics.processed.inc(n);
        this.log.info({ approved: n }, 'processed queue');
      }
      this.metrics.queueDepth.set(await this.store.queueDepth());
      this.metrics.lastRun.set(Date.now() / 1000);
    } catch (err) {
      this.metrics.errors.inc();
      this.log.error({ err }, 'queue run failed');
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    await this.running; // finish the run in progress (one transaction, short)
  }
}

export function buildWorkerApp(o: { store: Store; metrics: WorkerMetrics; breaker: Breaker<WorkerMode>; adminToken: string | null;
  isReady?: () => boolean; logLevel?: string }): FastifyInstance {
  const isReady = o.isReady ?? (() => true);
  const adminLimiter = new RateLimiter(30, 60_000);
  const app = Fastify({ logger: { level: o.logLevel ?? 'info' }, logController: new LogController({ disableRequestLogging: true }), bodyLimit: 4096, forceCloseConnections: 'idle' });

  app.get('/healthz', async () => ({ status: 'ok' }));
  app.get('/readyz', async (_req, reply) => {
    if (!isReady()) return reply.code(503).send({ status: 'starting' });
    try {
      await Promise.race([o.store.ping(), sleep(2000).then(() => { throw new Error('ping timeout'); })]);
      return { status: 'ok', db: 'ok' };
    } catch {
      return reply.code(503).send({ status: 'unavailable', db: 'unreachable' });
    }
  });
  app.get('/metrics', async (_req, reply) => reply.type(o.metrics.registry.contentType).send(await o.metrics.registry.metrics()));

  const admin = (req: FastifyRequest, reply: FastifyReply) => {
    if (!o.adminToken) { reply.code(404).send({ error: 'not found' }); return false; }
    if (!adminLimiter.hit(clientIp(req.headers, req.socket.remoteAddress)).allowed) { reply.code(429).send({ error: 'too many requests' }); return false; }
    if (!tokenOk(o.adminToken, req.headers['x-admin-token'])) { reply.code(401).send({ error: 'bad or missing X-Admin-Token' }); return false; }
    return true;
  };

  app.post('/admin/break', async (req, reply) => {
    if (!admin(req, reply)) return reply;
    const mode = ((req.body ?? {}) as { mode?: unknown }).mode;
    if (!(WORKER_MODES as readonly unknown[]).includes(mode)) {
      return reply.code(400).send({ error: `mode must be one of: ${WORKER_MODES.join(', ')}` });
    }
    o.breaker.set(mode as WorkerMode);
    o.metrics.stuck.set(1);
    req.log.warn({ mode }, 'BREAK MODE ON (demo): worker stops processing, heartbeat will go stale');
    return { ok: true, mode };
  });

  app.post('/admin/fix', async (req, reply) => {
    if (!admin(req, reply)) return reply;
    o.breaker.clear();
    o.metrics.stuck.set(0);
    req.log.warn('worker break mode cleared (demo)');
    return { ok: true };
  });

  return app;
}
