// Entry point: the queue worker, with /healthz, /readyz, /metrics and /admin/* on WORKER_PORT.
import { Breaker } from './breaker.ts';
import type { WorkerMode } from './breaker.ts';
import { loadConfig } from './config.ts';
import { createWorkerMetrics } from './metrics.ts';
import { MEMORY_WARNING, initInBackground, onShutdown, openStore } from './runtime.ts';
import { QueueWorker, buildWorkerApp } from './worker-app.ts';

const cfg = loadConfig();
const store = openStore(cfg);
const metrics = createWorkerMetrics();
const breaker = new Breaker<WorkerMode>();
let isReady = () => false;
const app = buildWorkerApp({ store, metrics, breaker, adminToken: cfg.adminToken, isReady: () => isReady(), logLevel: cfg.logLevel });
if (!cfg.db) app.log.warn(MEMORY_WARNING);

const boot = new AbortController();
isReady = initInBackground(store, app.log, boot.signal);
const worker = new QueueWorker({ store, metrics, breaker, intervalMs: cfg.workerIntervalMs, log: app.log });

// Start processing once the schema exists.
const waitReady = setInterval(() => { if (isReady()) { clearInterval(waitReady); worker.start(); } }, 250);

onShutdown(app.log, cfg.shutdownTimeoutMs, async () => {
  boot.abort();
  clearInterval(waitReady);
  await worker.stop();      // lets the current run (one short transaction) finish
  await app.close();
  await store.close();
});

await app.listen({ host: '0.0.0.0', port: cfg.workerPort });
