// MariaDB implementation of Store (mysql2). Connection settings come from the platform's `atlas-db` Secret.
import mysql from 'mysql2/promise';
import type { Pool, RowDataPacket, ResultSetHeader, PoolConnection } from 'mysql2/promise';
import type { DbConfig } from './config.ts';
import type { Entry, Stats, Store } from './store.ts';

// Times are DATETIME in UTC written by the app (UTC_TIMESTAMP), so DATE(created_at) is a UTC day whatever the
// server's time zone. Schema changes must stay additive: during a rolling deploy the previous release keeps running.
const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS entries (
     id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
     name VARCHAR(40) NOT NULL,
     message VARCHAR(280) NOT NULL,
     created_at DATETIME(3) NOT NULL,
     approved_at DATETIME(3) NULL,
     KEY idx_entries_created (created_at)
   ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`,
  `CREATE TABLE IF NOT EXISTS entry_queue (
     entry_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
     enqueued_at DATETIME(3) NOT NULL
   ) ENGINE=InnoDB`,
  `CREATE TABLE IF NOT EXISTS daily_stats (
     day DATE NOT NULL PRIMARY KEY,
     entries INT UNSIGNED NOT NULL DEFAULT 0,
     updated_at DATETIME(3) NOT NULL
   ) ENGINE=InnoDB`,
];

interface EntryRow extends RowDataPacket {
  id: number;
  name: string;
  message: string;
  created_at: Date;
  approved_at: Date | null;
}

export class MariaDbStore implements Store {
  private pool: Pool;

  constructor(cfg: DbConfig, connectionLimit = 5) {
    this.pool = mysql.createPool({
      host: cfg.host,
      port: cfg.port,
      database: cfg.database,
      user: cfg.user,
      password: cfg.password,
      connectionLimit,
      waitForConnections: true,
      queueLimit: 50,
      connectTimeout: 3000,
      enableKeepAlive: true,
      timezone: 'Z',
      supportBigNumbers: true,
      bigNumberStrings: false,
      charset: 'utf8mb4_unicode_ci',
    });
  }

  async init(): Promise<void> {
    const conn = await this.pool.getConnection();
    try {
      // Two copies starting at once (rolling deploy) take turns; CREATE TABLE IF NOT EXISTS is idempotent anyway.
      const [rows] = await conn.query<RowDataPacket[]>("SELECT GET_LOCK('anvil_demo_schema', 30) AS got");
      if (rows[0]?.got !== 1) throw new Error('could not take the schema lock within 30 s');
      try {
        for (const sql of SCHEMA) await conn.query(sql);
      } finally {
        await conn.query("SELECT RELEASE_LOCK('anvil_demo_schema')");
      }
    } finally {
      conn.release();
    }
  }

  async ping(): Promise<void> {
    await this.pool.query('SELECT 1');
  }

  async addEntry(name: string, message: string): Promise<Entry> {
    return this.tx(async (conn) => {
      const [res] = await conn.execute<ResultSetHeader>(
        'INSERT INTO entries (name, message, created_at) VALUES (?, ?, UTC_TIMESTAMP(3))', [name, message]);
      await conn.execute('INSERT INTO entry_queue (entry_id, enqueued_at) VALUES (?, UTC_TIMESTAMP(3))', [res.insertId]);
      const [rows] = await conn.execute<EntryRow[]>('SELECT * FROM entries WHERE id = ?', [res.insertId]);
      return toEntry(rows[0]!);
    });
  }

  async latestEntries(limit: number): Promise<Entry[]> {
    const [rows] = await this.pool.query<EntryRow[]>(
      'SELECT id, name, message, created_at, approved_at FROM entries ORDER BY id DESC LIMIT ?', [limit]);
    return rows.map(toEntry);
  }

  async stats(): Promise<Stats> {
    const [rows] = await this.pool.query<RowDataPacket[]>(
      `SELECT (SELECT COUNT(*) FROM entries) AS total,
              (SELECT COUNT(*) FROM entry_queue) AS pending,
              (SELECT COALESCE(MAX(entries), 0) FROM daily_stats WHERE day = UTC_DATE()) AS today`);
    const r: Record<string, unknown> = rows[0] ?? {};
    return { total: Number(r.total ?? 0), pending: Number(r.pending ?? 0), today: Number(r.today ?? 0) };
  }

  async processQueue(batch: number): Promise<number> {
    return this.tx(async (conn) => {
      // SKIP LOCKED: a second worker (there should be one, but a rolling restart can overlap) takes other rows.
      const [rows] = await conn.query<RowDataPacket[]>(
        `SELECT q.entry_id AS id, DATE_FORMAT(e.created_at, '%Y-%m-%d') AS day
           FROM entry_queue q JOIN entries e ON e.id = q.entry_id
          ORDER BY q.entry_id LIMIT ? FOR UPDATE SKIP LOCKED`, [batch]);
      if (rows.length === 0) return 0;
      const ids = rows.map((r) => Number(r.id));
      const perDay = new Map<string, number>();
      for (const r of rows) perDay.set(String(r.day), (perDay.get(String(r.day)) ?? 0) + 1);
      await conn.query('UPDATE entries SET approved_at = UTC_TIMESTAMP(3) WHERE id IN (?)', [ids]);
      for (const [day, n] of perDay) {
        await conn.execute(
          `INSERT INTO daily_stats (day, entries, updated_at) VALUES (?, ?, UTC_TIMESTAMP(3))
           ON DUPLICATE KEY UPDATE entries = entries + VALUES(entries), updated_at = VALUES(updated_at)`, [day, n]);
      }
      await conn.query('DELETE FROM entry_queue WHERE entry_id IN (?)', [ids]);
      return ids.length;
    });
  }

  async queueDepth(): Promise<number> {
    const [rows] = await this.pool.query<RowDataPacket[]>('SELECT COUNT(*) AS n FROM entry_queue');
    return Number(rows[0]?.n ?? 0);
  }

  async close(): Promise<void> {
    await this.pool.end();
  }

  private async tx<T>(fn: (conn: PoolConnection) => Promise<T>): Promise<T> {
    const conn = await this.pool.getConnection();
    try {
      await conn.beginTransaction();
      const out = await fn(conn);
      await conn.commit();
      return out;
    } catch (err) {
      await conn.rollback().catch(() => {});
      throw err;
    } finally {
      conn.release();
    }
  }
}

function toEntry(r: EntryRow): Entry {
  return { id: Number(r.id), name: r.name, message: r.message, createdAt: r.created_at, approved: r.approved_at !== null };
}
