// The live-demo break switch. State lives in memory only, so restarting the process (the autopilot's main move)
// always fixes it.

export const WEB_MODES = ['hang', 'slow', 'errors', 'crash'] as const;
export const WORKER_MODES = ['stuck'] as const;
export type WebMode = (typeof WEB_MODES)[number];
export type WorkerMode = (typeof WORKER_MODES)[number];

export class Breaker<M extends string> {
  mode: M | null = null;
  since: Date | null = null;
  private waiters = new Set<() => void>();

  set(mode: M): void {
    this.mode = mode;
    this.since = new Date();
  }

  clear(): void {
    this.mode = null;
    this.since = null;
    this.releaseAll();
  }

  /** Park a request until the mode is cleared or the process shuts down (used by `hang`). */
  wait(): Promise<void> {
    return new Promise((resolve) => this.waiters.add(resolve));
  }

  releaseAll(): void {
    for (const w of this.waiters) w();
    this.waiters.clear();
  }

  get waiting(): number {
    return this.waiters.size;
  }
}
