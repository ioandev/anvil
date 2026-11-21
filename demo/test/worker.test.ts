import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Breaker } from '../src/breaker.ts';
import type { WorkerMode } from '../src/breaker.ts';
import { createWorkerMetrics } from '../src/metrics.ts';
import { MemoryStore } from '../src/store.ts';
import { QueueWorker, buildWorkerApp } from '../src/worker-app.ts';

const TOKEN = 'test-token-not-a-secret';
const ADMIN = { 'content-type': 'application/json', 'x-admin-token': TOKEN };
const silent = { info() {}, warn() {}, error() {} } as never;

async function heartbeat(m: ReturnType<typeof createWorkerMetrics>): Promise<number> {
  return (await m.lastRun.get()).values[0]?.value ?? 0;
}

test('worker approves queued entries, counts them per day and updates the heartbeat', async () => {
  const store = new MemoryStore();
  const metrics = createWorkerMetrics(false);
  const w = new QueueWorker({ store, metrics, breaker: new Breaker<WorkerMode>(), intervalMs: 1000, log: silent });
  await store.addEntry('a', 'b');
  await store.addEntry('c', 'd');
  await w.tick();
  assert.equal(store.entries.every((e) => e.approved), true);
  assert.equal((await store.stats()).today, 2);
  assert.equal((await store.stats()).pending, 0);
  assert.ok(await heartbeat(metrics) > Date.now() / 1000 - 5);
});

test('stuck mode: no processing, heartbeat frozen, /healthz still 200; fix resumes', async () => {
  const store = new MemoryStore();
  const metrics = createWorkerMetrics(false);
  const breaker = new Breaker<WorkerMode>();
  const w = new QueueWorker({ store, metrics, breaker, intervalMs: 1000, log: silent });
  const app = buildWorkerApp({ store, metrics, breaker, adminToken: TOKEN, logLevel: 'silent' });

  assert.equal((await app.inject({ method: 'POST', url: '/admin/break', headers: ADMIN, payload: { mode: 'stuck' } })).statusCode, 200);
  await store.addEntry('a', 'b');
  await w.tick();
  assert.equal(store.entries[0]!.approved, false);
  assert.equal(await heartbeat(metrics), 0);
  assert.equal((await app.inject('/healthz')).statusCode, 200);
  assert.equal((await app.inject('/readyz')).statusCode, 200);
  assert.match((await app.inject('/metrics')).body, /anvil_demo_worker_stuck\{app="anvil-demo",component="worker"\} 1/);

  assert.equal((await app.inject({ method: 'POST', url: '/admin/fix', headers: ADMIN, payload: {} })).statusCode, 200);
  await w.tick();
  assert.equal(store.entries[0]!.approved, true);
  assert.ok(await heartbeat(metrics) > 0);
});

test('worker admin: auth and modes', async () => {
  const store = new MemoryStore();
  const metrics = createWorkerMetrics(false);
  const breaker = new Breaker<WorkerMode>();
  const app = buildWorkerApp({ store, metrics, breaker, adminToken: TOKEN, logLevel: 'silent' });
  assert.equal((await app.inject({ method: 'POST', url: '/admin/break', headers: { 'content-type': 'application/json' }, payload: { mode: 'stuck' } })).statusCode, 401);
  assert.equal((await app.inject({ method: 'POST', url: '/admin/break', headers: ADMIN, payload: { mode: 'hang' } })).statusCode, 400);
  const off = buildWorkerApp({ store, metrics, breaker, adminToken: null, logLevel: 'silent' });
  assert.equal((await off.inject({ method: 'POST', url: '/admin/break', headers: ADMIN, payload: { mode: 'stuck' } })).statusCode, 404);
});

test('a database outage counts an error and leaves the heartbeat stale', async () => {
  const store = new MemoryStore();
  const metrics = createWorkerMetrics(false);
  const w = new QueueWorker({ store, metrics, breaker: new Breaker<WorkerMode>(), intervalMs: 1000, log: silent });
  store.failing = true;
  await w.tick();
  assert.equal(await heartbeat(metrics), 0);
  assert.equal((await metrics.errors.get()).values[0]?.value, 1);
});
