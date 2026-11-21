// All configuration comes from the environment (12-factor). Nothing secret is baked into the image.

export interface DbConfig {
  host: string;
  port: number;
  database: string;
  user: string;
  password: string;
}

export interface Config {
  port: number;             // web + API (public, behind the Ingress)
  metricsPort: number;      // web's /metrics (cluster-internal only)
  workerPort: number;       // worker's /healthz, /readyz, /metrics, /admin/*
  db: DbConfig | null;      // null only with DEMO_MEMORY_STORE=1 (local playing around, never production)
  adminToken: string | null;
  rateLimitMax: number;
  rateLimitWindowMs: number;
  slowMs: number;
  peersHost: string | null; // headless Service: /admin/break and /admin/fix reach every web pod
  podIp: string | null;
  workerAdminUrl: string | null;
  workerIntervalMs: number;
  breakOnStart: boolean;
  shutdownTimeoutMs: number;
  logLevel: string;
}

function int(env: NodeJS.ProcessEnv, name: string, fallback: number, min = 0): number {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < min) throw new Error(`${name} must be an integer >= ${min}, got "${raw}"`);
  return n;
}

function str(env: NodeJS.ProcessEnv, name: string): string | null {
  const v = env[name]?.trim();
  return v ? v : null;
}

function bool(env: NodeJS.ProcessEnv, name: string): boolean {
  return ['1', 'true', 'yes'].includes((env[name] ?? '').trim().toLowerCase());
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  let db: DbConfig | null = null;
  if (!bool(env, 'DEMO_MEMORY_STORE')) {
    const missing = ['DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASSWORD'].filter((k) => !str(env, k));
    if (missing.length) throw new Error(`missing env: ${missing.join(', ')} (or set DEMO_MEMORY_STORE=1 to run without a database)`);
    db = {
      host: str(env, 'DB_HOST')!,
      port: int(env, 'DB_PORT', 3306, 1),
      database: str(env, 'DB_NAME')!,
      user: str(env, 'DB_USER')!,
      password: env.DB_PASSWORD!,
    };
  }
  return {
    port: int(env, 'PORT', 8080, 1),
    metricsPort: int(env, 'METRICS_PORT', 9090, 1),
    workerPort: int(env, 'WORKER_PORT', 8081, 1),
    db,
    adminToken: str(env, 'ADMIN_TOKEN'),
    rateLimitMax: int(env, 'RATE_LIMIT_MAX', 5, 1),
    rateLimitWindowMs: int(env, 'RATE_LIMIT_WINDOW_SECONDS', 60, 1) * 1000,
    slowMs: int(env, 'SLOW_MS', 8000, 0),
    peersHost: str(env, 'PEERS_HOST'),
    podIp: str(env, 'POD_IP'),
    workerAdminUrl: str(env, 'WORKER_ADMIN_URL'),
    workerIntervalMs: int(env, 'WORKER_INTERVAL_SECONDS', 5, 1) * 1000,
    breakOnStart: bool(env, 'BREAK_ON_START'),
    shutdownTimeoutMs: int(env, 'SHUTDOWN_TIMEOUT_SECONDS', 10, 1) * 1000,
    logLevel: str(env, 'LOG_LEVEL') ?? 'info',
  };
}
