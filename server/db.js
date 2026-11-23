// Database access for the API. The API never builds SQL from user text and never
// does ledger maths: it opens a transaction, calls ONE database function with bound
// parameters, and returns what the function returned.
import pg from 'pg';

// Keep timestamps as exact text. A JavaScript Date only holds milliseconds, but the
// history cursor needs the full microsecond value to page correctly.
pg.types.setTypeParser(pg.types.builtins.TIMESTAMPTZ, (value) => value);

function makePool(variable) {
  const connectionString = process.env[variable];
  if (!connectionString) return null;
  return new pg.Pool({ connectionString, max: 10 });
}

// ledger_app: money movement and reads. ledger_admin: freeze/unfreeze and reconciliation.
// Neither can touch a table. The owner pool below is reserved for the demo console.
export const pools = {
  app: makePool('APP_DATABASE_URL'),
  admin: makePool('ADMIN_DATABASE_URL'),
  // The owner login (DATABASE_URL). Used ONLY by the demo console (server/demo/), for
  // fixed attack and tamper statements. No ordinary route may use it.
  demo: makePool('DATABASE_URL'),
};

// One request = one connection from the pool = one transaction.
export async function callFunction(poolName, sql, params = []) {
  const pool = pools[poolName];
  if (!pool) {
    throw Object.assign(new Error(`${poolName} database login is not configured`), { status: 503 });
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(sql, params);
    await client.query('COMMIT');
    return rows;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}
