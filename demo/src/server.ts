// Entry point: web + API on PORT, Prometheus metrics on METRICS_PORT (cluster-internal, not on the Ingress).
import { createServer } from 'node:http';
import { buildWebApp } from './app.ts';
import { loadConfig } from './config.ts';
import { createWebMetrics } from './metrics.ts';
import { MEMORY_WARNING, initInBackground, onShutdown, openStore } from './runtime.ts';

const cfg = loadConfig();

if (cfg.breakOnStart) {
  // The "bad release" demo: deploying with BREAK_ON_START=1 is a crash loop, and `kubectl rollout undo` fixes it.
  console.error(JSON.stringify({ level: 60, time: Date.now(), msg: 'BREAK_ON_START is set: refusing to start (demo bad release)' }));
  process.exit(1);
}

const store = openStore(cfg);
const metrics = createWebMetrics();
let isReady = () => false;
const app = buildWebApp({
  store, metrics, adminToken: cfg.adminToken, rateLimitMax: cfg.rateLimitMax, rateLimitWindowMs: cfg.rateLimitWindowMs,
  slowMs: cfg.slowMs, port: cfg.port, peersHost: cfg.peersHost, podIp: cfg.podIp, workerAdminUrl: cfg.workerAdminUrl,
  isReady: () => isReady(), logLevel: cfg.logLevel,
});
if (!cfg.db) app.log.warn(MEMORY_WARNING);
if (!cfg.adminToken) app.log.warn('ADMIN_TOKEN not set: /admin/* is disabled');

const boot = new AbortController();
isReady = initInBackground(store, app.log, boot.signal);

const metricsServer = createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/metrics') {
    metrics.registry.metrics().then(
      (body) => { res.writeHead(200, { 'content-type': metrics.registry.contentType }); res.end(body); },
      () => { res.writeHead(500); res.end(); },
    );
    return;
  }
  res.writeHead(404); res.end();
});

onShutdown(app.log, cfg.shutdownTimeoutMs, async () => {
  boot.abort();
  await app.close();        // stops accepting, waits for in-flight requests (break modes release theirs)
  await new Promise<void>((r) => metricsServer.close(() => r()));
  await store.close();
});

await app.listen({ host: '0.0.0.0', port: cfg.port });
metricsServer.listen(cfg.metricsPort, '0.0.0.0', () => app.log.info({ port: cfg.metricsPort }, 'metrics listening'));
