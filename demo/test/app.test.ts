import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';
import { buildWebApp } from '../src/app.ts';
import type { WebAppOptions } from '../src/app.ts';
import { createWebMetrics } from '../src/metrics.ts';
import { MemoryStore } from '../src/store.ts';

const TOKEN = 'test-token-not-a-secret';
const JSON_HDR = { 'content-type': 'application/json' };
const ADMIN = { ...JSON_HDR, 'x-admin-token': TOKEN };

function make(over: Partial<WebAppOptions> = {}) {
  const store = new MemoryStore();
  const metrics = createWebMetrics(false);
  const exits: number[] = [];
  const app = buildWebApp({
    store, metrics, adminToken: TOKEN, rateLimitMax: 100, rateLimitWindowMs: 60_000, slowMs: 150,
    exit: (c) => exits.push(c), logLevel: 'silent', ...over,
  });
  return { app, store, metrics, exits };
}

test('GET / renders the page with entries, escaped', async () => {
  const { app, store } = make();
  await store.addEntry('<b>Bob</b>', 'hi <script>x</script>');
  const res = await app.inject({ method: 'GET', url: '/' });
  assert.equal(res.statusCode, 200);
  assert.match(res.headers['content-type'] as string, /text\/html/);
  assert.ok(res.body.includes('&lt;b&gt;Bob&lt;/b&gt;'));
  assert.ok(!res.body.includes('<script>x'));
  assert.ok(res.headers['content-security-policy']);
});

test('POST /api/entries (JSON): 201, then listed by GET /api/entries', async () => {
  const { app, metrics } = make();
  const res = await app.inject({ method: 'POST', url: '/api/entries', headers: JSON_HDR, payload: { name: 'Ada', message: 'Hello' } });
  assert.equal(res.statusCode, 201);
  assert.equal(res.json().entry.name, 'Ada');
  const list = await app.inject({ method: 'GET', url: '/api/entries?limit=5' });
  assert.equal(list.json().entries.length, 1);
  assert.equal(list.json().entries[0].approved, false);
  assert.match(await metrics.registry.metrics(), /anvil_demo_entries_created_total\{app="anvil-demo",component="web"\} 1/);
});

test('POST /api/entries: invalid input is a 400 with field errors', async () => {
  const { app } = make();
  const res = await app.inject({ method: 'POST', url: '/api/entries', headers: JSON_HDR, payload: { name: '', message: 'x'.repeat(281) } });
  assert.equal(res.statusCode, 400);
  assert.deepEqual(Object.keys(res.json().fields).sort(), ['message', 'name']);
});

test('POST /api/entries (HTML form): 303 to /?posted=1; errors re-render the form', async () => {
  const { app } = make();
  const form = { 'content-type': 'application/x-www-form-urlencoded' };
  const ok = await app.inject({ method: 'POST', url: '/api/entries', headers: form, payload: 'name=Ada&message=Hi+there' });
  assert.equal(ok.statusCode, 303);
  assert.equal(ok.headers.location, '/?posted=1');
  const bad = await app.inject({ method: 'POST', url: '/api/entries', headers: form, payload: 'name=%3Cx%3E&message=' });
  assert.equal(bad.statusCode, 400);
  assert.ok(bad.body.includes('message is required'));
  assert.ok(bad.body.includes('value="&lt;x&gt;"'));
});

test('rate limit is per CF-Connecting-IP', async () => {
  const { app } = make({ rateLimitMax: 2 });
  const post = (ip: string) => app.inject({ method: 'POST', url: '/api/entries', headers: { ...JSON_HDR, 'cf-connecting-ip': ip }, payload: { name: 'a', message: 'b' } });
  assert.equal((await post('203.0.113.1')).statusCode, 201);
  assert.equal((await post('203.0.113.1')).statusCode, 201);
  const third = await post('203.0.113.1');
  assert.equal(third.statusCode, 429);
  assert.ok(Number(third.headers['retry-after']) > 0);
  assert.equal((await post('203.0.113.2')).statusCode, 201, 'another visitor is not affected');
});

test('probes: /healthz never touches the DB; /readyz follows it', async () => {
  const { app, store } = make();
  assert.equal((await app.inject('/readyz')).statusCode, 200);
  store.failing = true;
  assert.equal((await app.inject('/healthz')).statusCode, 200);
  assert.equal((await app.inject('/readyz')).statusCode, 503);
  assert.equal((await app.inject('/api/entries')).statusCode, 503);
  assert.equal((await app.inject('/')).statusCode, 503);
});

test('/readyz is 503 until the schema is ready', async () => {
  const { app } = make({ isReady: () => false });
  assert.equal((await app.inject('/readyz')).statusCode, 503);
});

test('admin: 404 without ADMIN_TOKEN, 401 with a wrong one, 400 on an unknown mode', async () => {
  const off = make({ adminToken: null }).app;
  assert.equal((await off.inject({ method: 'POST', url: '/admin/break', headers: { ...ADMIN }, payload: { mode: 'errors' } })).statusCode, 404);
  const { app } = make();
  assert.equal((await app.inject({ method: 'POST', url: '/admin/break', headers: { ...JSON_HDR, 'x-admin-token': 'nope' }, payload: { mode: 'errors' } })).statusCode, 401);
  assert.equal((await app.inject({ method: 'POST', url: '/admin/break', headers: JSON_HDR, payload: { mode: 'errors' } })).statusCode, 401);
  assert.equal((await app.inject({ method: 'POST', url: '/admin/break', headers: ADMIN, payload: { mode: 'meltdown' } })).statusCode, 400);
});

test('break errors: API and readiness 500, liveness stays 200; fix restores', async () => {
  const { app, metrics } = make();
  assert.equal((await app.inject({ method: 'POST', url: '/admin/break', headers: ADMIN, payload: { mode: 'errors' } })).statusCode, 200);
  assert.equal((await app.inject('/api/entries')).statusCode, 500);
  assert.equal((await app.inject('/')).statusCode, 500);
  assert.equal((await app.inject('/readyz')).statusCode, 500);
  assert.equal((await app.inject('/healthz')).statusCode, 200);
  assert.match(await metrics.registry.metrics(), /anvil_demo_break_mode\{mode="errors",app="anvil-demo",component="web"\} 1/);
  assert.equal((await app.inject({ method: 'POST', url: '/admin/fix', headers: ADMIN, payload: {} })).statusCode, 200);
  assert.equal((await app.inject('/api/entries')).statusCode, 200);
  assert.equal((await app.inject('/readyz')).statusCode, 200);
});

test('break slow: every response is delayed (probes included)', async () => {
  const { app } = make({ slowMs: 200 });
  await app.inject({ method: 'POST', url: '/admin/break', headers: ADMIN, payload: { mode: 'slow' } });
  const t = Date.now();
  assert.equal((await app.inject('/healthz')).statusCode, 200);
  assert.ok(Date.now() - t >= 190, 'delayed');
  await app.inject({ method: 'POST', url: '/admin/fix', headers: ADMIN, payload: {} });
  const t2 = Date.now();
  await app.inject('/healthz');
  assert.ok(Date.now() - t2 < 100, 'fast again');
});

test('break hang: nothing answers (not even /healthz) until fixed; admin still works', async () => {
  const { app } = make();
  await app.inject({ method: 'POST', url: '/admin/break', headers: ADMIN, payload: { mode: 'hang' } });
  let done = false;
  const pending = app.inject('/healthz').then((r) => { done = true; return r; });
  await sleep(150);
  assert.equal(done, false, '/healthz is hanging');
  assert.equal(app.breaker.waiting, 1);
  assert.equal((await app.inject({ method: 'POST', url: '/admin/fix', headers: ADMIN, payload: {} })).statusCode, 200);
  assert.equal((await pending).statusCode, 200, 'released by the fix');
});

test('break hang: shutdown releases parked requests with 503', async () => {
  const { app } = make();
  await app.inject({ method: 'POST', url: '/admin/break', headers: ADMIN, payload: { mode: 'hang' } });
  const pending = app.inject('/api/entries');
  await sleep(50);
  await app.close();
  assert.equal((await pending).statusCode, 503);
});

test('break crash: responds, then exits with status 1', async () => {
  const { app, exits } = make();
  const res = await app.inject({ method: 'POST', url: '/admin/break', headers: ADMIN, payload: { mode: 'crash' } });
  assert.equal(res.statusCode, 200);
  await sleep(10);
  assert.deepEqual(exits, [1]);
  assert.equal(app.breaker.mode, null, 'crash is a one-off, not a state');
});

test('break fans out to the other web pods and stuck goes to the worker', async () => {
  const calls: { url: string; body: unknown; headers: Record<string, string> }[] = [];
  const fetchFn = (async (url: string, init: RequestInit) => {
    calls.push({ url, body: JSON.parse(String(init.body)), headers: init.headers as Record<string, string> });
    return new Response('{}', { status: 200 });
  }) as unknown as typeof fetch;
  const { app } = make({
    port: 8080, peersHost: 'peers', podIp: '10.0.0.1', resolvePeers: async () => ['10.0.0.1', '10.0.0.2', '10.0.0.3'],
    workerAdminUrl: 'http://worker:8081', fetchFn,
  });
  const res = await app.inject({ method: 'POST', url: '/admin/break', headers: ADMIN, payload: { mode: 'errors' } });
  assert.equal(res.json().peers.length, 2);
  assert.deepEqual(calls.map((c) => c.url).sort(), ['http://10.0.0.2:8080/admin/break', 'http://10.0.0.3:8080/admin/break']);
  assert.equal(calls[0]!.headers['x-anvil-fanout'], '1');
  assert.deepEqual(calls[0]!.body, { mode: 'errors', all: false });

  calls.length = 0;
  const stuck = await app.inject({ method: 'POST', url: '/admin/break', headers: ADMIN, payload: { mode: 'stuck' } });
  assert.equal(stuck.statusCode, 200);
  assert.deepEqual(calls.map((c) => c.url), ['http://worker:8081/admin/break']);

  calls.length = 0;
  await app.inject({ method: 'POST', url: '/admin/fix', headers: ADMIN, payload: {} });
  assert.deepEqual(calls.map((c) => c.url).sort(), ['http://10.0.0.2:8080/admin/fix', 'http://10.0.0.3:8080/admin/fix', 'http://worker:8081/admin/fix']);

  // A forwarded call (from a peer) is not forwarded again.
  calls.length = 0;
  await app.inject({ method: 'POST', url: '/admin/break', headers: { ...ADMIN, 'x-anvil-fanout': '1' }, payload: { mode: 'slow' } });
  assert.equal(calls.length, 0);
});

test('metrics count requests by route and status', async () => {
  const { app, metrics } = make();
  await app.inject('/api/entries');
  await app.inject('/nope');
  const text = await metrics.registry.metrics();
  assert.match(text, /anvil_demo_http_requests_total\{method="GET",route="\/api\/entries",status_code="200"/);
  assert.match(text, /route="unmatched",status_code="404"/);
});
