import { Pool } from "pg";
import { SUPABASE_ROOT_CA } from "./supabase-ca";

/**
 * Postgres connection to Supabase.
 *
 * Two things differ from a normal long-running server, and both come from
 * running on Vercel:
 *
 * **max: 1, not 5.** Every warm serverless instance holds its own pool, and
 * there can be many of them at once. A pool of five per instance multiplies
 * straight into Supabase's connection limit, which on the free tier is not
 * generous. One connection per instance, released quickly, is what scales
 * here — concurrency comes from more instances, not a bigger pool.
 *
 * **The transaction pooler (:6543), not the direct connection.** Serverless
 * cold-starts constantly, and Supavisor in transaction mode is built for
 * exactly that churn. Transactions still work — `approveDraft()` runs
 * BEGIN/COMMIT and the pooler pins a backend for the duration.
 *
 * n8n deliberately uses the *session* pooler (:5432) instead: it holds
 * long-lived connections from one host and wants something closest to a
 * direct connection. Same database, different front door, for good reasons on
 * each side.
 *
 * ACQ_DATABASE_URL must authenticate as `acq_dashboard` (migration 010), NOT
 * as `postgres`. That role cannot read acq.leads, acq.opt_outs or cached
 * research, and cannot alter an email's recipient — so this connection string
 * leaking is a bad day rather than a breach of every clinic's contact details.
 */
const globalForPg = globalThis as unknown as { acqPool?: Pool };

export const pool =
  globalForPg.acqPool ??
  new Pool({
    connectionString: process.env.ACQ_DATABASE_URL,
    max: 1,
    idleTimeoutMillis: 10_000,
    connectionTimeoutMillis: 10_000,
    // The dashboard is read-mostly; a slow query is a bug, not something to
    // wait out behind a page that never renders.
    statement_timeout: 10_000,
    // Supabase requires TLS, and its pooler is signed by Supabase's own
    // private root — not one Node ships with. Passing that CA is what makes
    // `rejectUnauthorized: true` actually work here; without it `pg` throws
    // "self-signed certificate in certificate chain", and the usual answer
    // (rejectUnauthorized: false) keeps the encryption while discarding the
    // authentication that stops someone answering in Supabase's place.
    ssl: { rejectUnauthorized: true, ca: SUPABASE_ROOT_CA },
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
