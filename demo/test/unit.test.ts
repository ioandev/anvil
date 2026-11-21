import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MESSAGE_MAX, NAME_MAX, validateEntry } from '../src/validate.ts';
import { escapeHtml, renderPage } from '../src/html.ts';
import { RateLimiter, clientIp } from '../src/ratelimit.ts';
import { tokenOk } from '../src/admin.ts';
import { loadConfig } from '../src/config.ts';

test('validation: accepts and trims a normal entry', () => {
  const r = validateEntry({ name: '  Ada  Lovelace ', message: '  Hello\r\nworld  ' });
  assert.deepEqual(r, { ok: true, value: { name: 'Ada Lovelace', message: 'Hello\nworld' } });
});

test('validation: missing, empty and wrong-type fields', () => {
  assert.deepEqual(validateEntry({}), { ok: false, errors: { name: 'name is required', message: 'message is required' } });
  assert.equal(validateEntry({ name: '   ', message: 'x' }).ok, false);
  assert.equal(validateEntry({ name: 42, message: 'x' }).ok, false);
  assert.equal(validateEntry(null).ok, false);
  assert.equal(validateEntry('name=x').ok, false);
});

test('validation: length limits are in characters, not bytes', () => {
  assert.equal(validateEntry({ name: 'a'.repeat(NAME_MAX), message: 'ok' }).ok, true);
  assert.equal(validateEntry({ name: 'a'.repeat(NAME_MAX + 1), message: 'ok' }).ok, false);
  assert.equal(validateEntry({ name: 'x', message: '🔨'.repeat(MESSAGE_MAX) }).ok, true);
  assert.equal(validateEntry({ name: 'x', message: '🔨'.repeat(MESSAGE_MAX + 1) }).ok, false);
});

test('validation: rejects control and bidi-override characters', () => {
  assert.equal(validateEntry({ name: 'a\u0000b', message: 'x' }).ok, false);
  assert.equal(validateEntry({ name: 'x', message: 'evil‮txt' }).ok, false);
});

test('escapeHtml escapes the five HTML-special characters', () => {
  assert.equal(escapeHtml(`<a href="x" onclick='y'>&</a>`), '&lt;a href=&quot;x&quot; onclick=&#39;y&#39;&gt;&amp;&lt;/a&gt;');
});

test('renderPage never outputs user input raw', () => {
  const html = renderPage({
    entries: [{ id: 1, name: '<script>alert(1)</script>', message: '"><img src=x onerror=alert(1)>', createdAt: new Date(0), approved: false }],
    stats: { total: 1, pending: 1, today: 0 }, podName: '<pod>', form: { name: '"><b>', message: '</textarea><script>' },
  });
  assert.ok(!html.includes('<script>alert'));
  assert.ok(!html.includes('<img'));
  assert.ok(!html.includes('</textarea><script>'));
  assert.ok(html.includes('&lt;script&gt;alert(1)&lt;/script&gt;'));
  assert.ok(html.includes('pending'));
});

test('rate limiter: N per window per key, then 429 until the window resets', () => {
  let now = 1_000_000;
  const rl = new RateLimiter(3, 60_000, () => now);
  assert.equal(rl.hit('1.1.1.1').allowed, true);
  assert.equal(rl.hit('1.1.1.1').allowed, true);
  assert.equal(rl.hit('1.1.1.1').allowed, true);
  const blocked = rl.hit('1.1.1.1');
  assert.equal(blocked.allowed, false);
  assert.equal(blocked.retryAfterSeconds, 60);
  assert.equal(rl.hit('2.2.2.2').allowed, true, 'other IPs have their own budget');
  now += 60_000;
  assert.equal(rl.hit('1.1.1.1').allowed, true, 'new window');
});

test('clientIp prefers a valid CF-Connecting-IP, else the socket address', () => {
  assert.equal(clientIp({ 'cf-connecting-ip': '203.0.113.7' }, '10.42.0.5'), '203.0.113.7');
  assert.equal(clientIp({ 'cf-connecting-ip': '2001:db8::1' }, '10.42.0.5'), '2001:db8::1');
  assert.equal(clientIp({ 'cf-connecting-ip': 'not-an-ip' }, '10.42.0.5'), '10.42.0.5');
  assert.equal(clientIp({ 'x-forwarded-for': '6.6.6.6, 10.42.0.1' }, '10.42.0.5'), '10.42.0.5', 'XFF is ignored');
});

test('tokenOk: constant-time compare, disabled without a token', () => {
  assert.equal(tokenOk('s3cret', 's3cret'), true);
  assert.equal(tokenOk('s3cret', 's3cre'), false);
  assert.equal(tokenOk('s3cret', undefined), false);
  assert.equal(tokenOk(null, ''), false);
  assert.equal(tokenOk(null, 'anything'), false);
});

test('config: requires DB_* unless DEMO_MEMORY_STORE=1', () => {
  assert.throws(() => loadConfig({}), /missing env: DB_HOST, DB_NAME, DB_USER, DB_PASSWORD/);
  const c = loadConfig({ DB_HOST: 'h', DB_NAME: 'n', DB_USER: 'u', DB_PASSWORD: 'p', DB_PORT: '3307' });
  assert.equal(c.db?.port, 3307);
  assert.equal(c.adminToken, null);
  assert.equal(loadConfig({ DEMO_MEMORY_STORE: '1' }).db, null);
  assert.throws(() => loadConfig({ DEMO_MEMORY_STORE: '1', PORT: 'abc' }), /PORT must be an integer/);
});
