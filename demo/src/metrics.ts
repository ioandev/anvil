// Prometheus metrics. Each process gets its own Registry (tests build several apps in one process).
import { Counter, Gauge, Histogram, Registry, collectDefaultMetrics } from 'prom-client';
import { WEB_MODES } from './breaker.ts';

export function createWebMetrics(defaults = true) {
  const registry = new Registry();
  registry.setDefaultLabels({ app: 'anvil-demo', component: 'web' });
  if (defaults) collectDefaultMetrics({ register: registry });
  const m = {
    registry,
    requests: new Counter({
      name: 'anvil_demo_http_requests_total', help: 'HTTP requests by method, route and status code.',
      labelNames: ['method', 'route', 'status_code'] as const, registers: [registry],
    }),
    duration: new Histogram({
      name: 'anvil_demo_http_request_duration_seconds', help: 'HTTP request latency.',
      labelNames: ['method', 'route'] as const, buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
      registers: [registry],
    }),
    entriesCreated: new Counter({
      name: 'anvil_demo_entries_created_total', help: 'Guestbook entries created by this process.', registers: [registry],
    }),
    dbErrors: new Counter({
      name: 'anvil_demo_db_errors_total', help: 'Database operations that failed.', labelNames: ['op'] as const,
      registers: [registry],
    }),
    rateLimited: new Counter({
      name: 'anvil_demo_rate_limited_total', help: 'Requests refused by the per-IP rate limit.', registers: [registry],
    }),
    breakMode: new Gauge({
      name: 'anvil_demo_break_mode', help: '1 for the break mode currently active in this process (0 otherwise).',
      labelNames: ['mode'] as const, registers: [registry],
    }),
  };
  for (const mode of WEB_MODES) m.breakMode.set({ mode }, 0);
  return m;
}
export type WebMetrics = ReturnType<typeof createWebMetrics>;

export function createWorkerMetrics(defaults = true) {
  const registry = new Registry();
  registry.setDefaultLabels({ app: 'anvil-demo', component: 'worker' });
  if (defaults) collectDefaultMetrics({ register: registry });
  return {
    registry,
    lastRun: new Gauge({
      name: 'anvil_demo_worker_last_run_timestamp_seconds',
      help: 'Unix time of the last successful queue run (the heartbeat: stale = worker stuck or database down).',
      registers: [registry],
    }),
    processed: new Counter({
      name: 'anvil_demo_worker_processed_total', help: 'Queue items processed (entries approved).', registers: [registry],
    }),
    queueDepth: new Gauge({
      name: 'anvil_demo_worker_queue_depth', help: 'Entries waiting in the queue at the last run.', registers: [registry],
    }),
    errors: new Counter({
      name: 'anvil_demo_worker_errors_total', help: 'Queue runs that failed.', registers: [registry],
    }),
    stuck: new Gauge({
      name: 'anvil_demo_worker_stuck', help: '1 while the demo "stuck" break mode is on.', registers: [registry],
    }),
  };
}
export type WorkerMetrics = ReturnType<typeof createWorkerMetrics>;
