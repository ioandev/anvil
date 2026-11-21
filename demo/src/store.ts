// The database behind an interface, so the HTTP layer and the worker can be tested without MariaDB.

export interface Entry {
  id: number;
  name: string;
  message: string;
  createdAt: Date;
  approved: boolean;
}

export interface Stats {
  total: number;
  pending: number;
  today: number; // computed by the worker (daily_stats), so it lags when the worker is stuck
}

export interface Store {
  /** Idempotent schema setup; safe when several copies start at once. */
  init(): Promise<void>;
  ping(): Promise<void>;
  addEntry(name: string, message: string): Promise<Entry>;
  latestEntries(limit: number): Promise<Entry[]>;
  stats(): Promise<Stats>;
  /** Worker: approve up to `batch` queued entries and count them per day. Returns how many it processed. */
  processQueue(batch: number): Promise<number>;
  queueDepth(): Promise<number>;
  close(): Promise<void>;
}

/** In-memory Store for tests and for DEMO_MEMORY_STORE=1. Not shared between processes. */
export class MemoryStore implements Store {
  entries: Entry[] = [];
  queue: number[] = [];
  daily = new Map<string, number>();
  failing = false; // tests flip this to simulate a database outage
  private nextId = 1;

  private check(): void {
    if (this.failing) throw new Error('database unavailable (simulated)');
  }
  async init(): Promise<void> { this.check(); }
  async ping(): Promise<void> { this.check(); }
  async addEntry(name: string, message: string): Promise<Entry> {
    this.check();
    const e: Entry = { id: this.nextId++, name, message, createdAt: new Date(), approved: false };
    this.entries.push(e);
    this.queue.push(e.id);
    return e;
  }
  async latestEntries(limit: number): Promise<Entry[]> {
    this.check();
    return [...this.entries].sort((a, b) => b.id - a.id).slice(0, limit);
  }
  async stats(): Promise<Stats> {
    this.check();
    const today = new Date().toISOString().slice(0, 10);
    return {
      total: this.entries.length,
      pending: this.entries.filter((e) => !e.approved).length,
      today: this.daily.get(today) ?? 0,
    };
  }
  async processQueue(batch: number): Promise<number> {
    this.check();
    const ids = this.queue.splice(0, batch);
    for (const id of ids) {
      const e = this.entries.find((x) => x.id === id);
      if (!e) continue;
      e.approved = true;
      const day = e.createdAt.toISOString().slice(0, 10);
      this.daily.set(day, (this.daily.get(day) ?? 0) + 1);
    }
    return ids.length;
  }
  async queueDepth(): Promise<number> { this.check(); return this.queue.length; }
  async close(): Promise<void> {}
}
