// Admin helpers: token check, and passing a break/fix on to the other web pods and to the worker, so one request
// through the public URL breaks (or fixes) the whole app on stage.
import { createHash, timingSafeEqual } from 'node:crypto';
import { lookup } from 'node:dns/promises';

export const FANOUT_HEADER = 'x-anvil-fanout';

export function tokenOk(expected: string | null, given: unknown): boolean {
  if (!expected || typeof given !== 'string' || given.length === 0) return false;
  const a = createHash('sha256').update(expected).digest();
  const b = createHash('sha256').update(given).digest();
  return timingSafeEqual(a, b);
}

export type ForwardResult = { target: string; status?: number; error?: string };
export type FetchFn = typeof fetch;

async function post(fetchFn: FetchFn, url: string, token: string, body: unknown, timeoutMs: number): Promise<ForwardResult> {
  try {
    const res = await fetchFn(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-admin-token': token, [FANOUT_HEADER]: '1' },
      body: JSON.stringify(body ?? {}),
      signal: AbortSignal.timeout(timeoutMs),
    });
    await res.arrayBuffer().catch(() => undefined);
    return { target: url, status: res.status };
  } catch (err) {
    return { target: url, error: (err as Error).message };
  }
}

export interface PeerOptions {
  host: string;                 // headless Service name: resolves to every web pod's IP (ready or not)
  port: number;
  selfIp: string | null;
  resolve?: (host: string) => Promise<string[]>;
  fetchFn?: FetchFn;
  timeoutMs?: number;
}

/** POST the same admin call to every other web pod. */
export async function forwardToPeers(o: PeerOptions, path: string, token: string, body: unknown): Promise<ForwardResult[]> {
  const resolve = o.resolve ?? (async (h: string) => (await lookup(h, { all: true })).map((a) => a.address));
  let ips: string[];
  try {
    ips = await resolve(o.host);
  } catch (err) {
    return [{ target: o.host, error: `resolve failed: ${(err as Error).message}` }];
  }
  const others = [...new Set(ips)].filter((ip) => ip !== o.selfIp);
  return Promise.all(others.map((ip) => {
    const h = ip.includes(':') ? `[${ip}]` : ip;
    return post(o.fetchFn ?? fetch, `http://${h}:${o.port}${path}`, token, body, o.timeoutMs ?? 2000);
  }));
}

export function forwardToWorker(baseUrl: string, path: string, token: string, body: unknown, fetchFn: FetchFn = fetch): Promise<ForwardResult> {
  return post(fetchFn, baseUrl.replace(/\/$/, '') + path, token, body, 2000);
}
