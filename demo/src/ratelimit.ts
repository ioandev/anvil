// Fixed-window rate limit per key (the client IP), in memory. Each web pod counts on its own, which is fine for a demo:
// with 2 replicas a visitor gets at most 2x the limit.
import { isIP } from 'node:net';

export class RateLimiter {
  private hits = new Map<string, { count: number; resetAt: number }>();
  private max: number;
  private windowMs: number;
  private now: () => number;

  constructor(max: number, windowMs: number, now: () => number = Date.now) {
    this.max = max;
    this.windowMs = windowMs;
    this.now = now;
  }

  /** Counts one hit for `key`. Returns whether it's allowed and, if not, how many seconds until it is. */
  hit(key: string): { allowed: boolean; retryAfterSeconds: number; remaining: number } {
    const t = this.now();
    let w = this.hits.get(key);
    if (!w || w.resetAt <= t) {
      w = { count: 0, resetAt: t + this.windowMs };
      this.hits.set(key, w);
    }
    w.count++;
    if (this.hits.size > 10_000) this.sweep(t);
    const allowed = w.count <= this.max;
    return { allowed, retryAfterSeconds: allowed ? 0 : Math.ceil((w.resetAt - t) / 1000), remaining: Math.max(0, this.max - w.count) };
  }

  private sweep(t: number): void {
    for (const [k, w] of this.hits) if (w.resetAt <= t) this.hits.delete(k);
  }
}

/**
 * The visitor's IP. Behind Cloudflare -> ServiceLB -> Traefik the socket address is an internal one, and the
 * left-most X-Forwarded-For entry is client-forgeable, so we trust Cloudflare's CF-Connecting-IP. That's only safe
 * because the origin accepts nothing but Cloudflare (firewall + Authenticated Origin Pulls).
 */
export function clientIp(headers: Record<string, string | string[] | undefined>, socketAddress: string | undefined): string {
  const raw = headers['cf-connecting-ip'];
  const cf = (Array.isArray(raw) ? raw[0] : raw)?.trim();
  if (cf && isIP(cf)) return cf;
  return socketAddress ?? 'unknown';
}
