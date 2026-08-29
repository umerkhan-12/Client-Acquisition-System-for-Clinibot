import { Pool } from "pg";

// One pool per process. Next dev reloads modules, so it is stashed on
// globalThis to avoid leaking a pool on every hot reload.
const globalForPg = globalThis as unknown as { acqPool?: Pool };

export const pool =
  globalForPg.acqPool ??
  new Pool({
    connectionString: process.env.ACQ_DATABASE_URL,
    max: 5,
    idleTimeoutMillis: 30_000,
    // The dashboard is read-mostly; a slow query is a bug, not something to
    // wait out behind a page that never renders.
    statement_timeout: 10_000,
  });

if (process.env.NODE_ENV !== "production") globalForPg.acqPool = pool;

export async function query<T = Record<string, unknown>>(
  text: string,
  params: unknown[] = [],
): Promise<T[]> {
  const res = await pool.query(text, params);
  return res.rows as T[];
}

/** Single-row helper for the overview tiles. */
export async function queryOne<T = Record<string, unknown>>(
  text: string,
  params: unknown[] = [],
): Promise<T | null> {
  const rows = await query<T>(text, params);
  return rows[0] ?? null;
}
