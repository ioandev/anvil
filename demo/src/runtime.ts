// Shared start-up/shut-down plumbing for the two entry points (server.ts, worker.ts).
import type { FastifyBaseLogger } from 'fastify';
import { setTimeout as sleep } from 'node:timers/promises';
import type { Config } from './config.ts';
import { MariaDbStore } from './mariadb.ts';
import { MemoryStore } from './store.ts';
import type { Store } from './store.ts';

export function openStore(cfg: Config): Store {
  return cfg.db ? new MariaDbStore(cfg.db) : new MemoryStore();
}

export const MEMORY_WARNING =
  'DEMO_MEMORY_STORE=1: using an in-memory store (lost on restart, not shared between processes; never in production)';

/**
 * Set up the schema, retrying until it works: the process starts (and answers /healthz) even while the database is
 * down, and /readyz stays 503 until this finishes. Returns a function telling whether it finished.
 */
export function initInBackground(store: Store, log: FastifyBaseLogger, signal: AbortSignal): () => boolean {
  let ready = false;
  void (async () => {
    for (let attempt = 1; !signal.aborted; attempt++) {
      try {
        await store.init();
        ready = true;
        log.info('schema ready');
        return;
      } catch (err) {
        log.error({ err, attempt }, 'schema setup failed, retrying');
        await sleep(Math.min(30_000, 1000 * 2 ** Math.min(attempt, 5)), undefined, { signal }).catch(() => undefined);
      }
    }
  })();
  return () => ready;
}

/**
 * SIGTERM/SIGINT: run `close` (stop accepting, finish in-flight work, close the pool), then exit 0. If that takes
 * longer than `timeoutMs`, exit 1 anyway so Kubernetes never has to SIGKILL us.
 */
export function onShutdown(log: FastifyBaseLogger, timeoutMs: number, close: () => Promise<void>): void {
  let started = false;
  const handler = (signal: string) => {
    if (started) return;
    started = true;
    log.info({ signal }, 'shutting down');
    setTimeout(() => { log.error('shutdown took too long, exiting'); process.exit(1); }, timeoutMs).unref();
    close().then(
      () => { log.info('bye'); process.exit(0); },
      (err) => { log.error({ err }, 'error during shutdown'); process.exit(1); },
    );
  };
  process.once('SIGTERM', () => handler('SIGTERM'));
  process.once('SIGINT', () => handler('SIGINT'));
}
