// Run the persistent, idempotent demo seed outside db:reset/db:apply.
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import pg from 'pg';

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL is not set. Add it to the .env file in the project folder.');
  process.exit(1);
}

const seedFile = path.join(import.meta.dirname, '..', 'demos', 'seed.sql');
const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
client.on('notice', (notice) => console.log(notice.message));

try {
  await client.connect();
  await client.query(await readFile(seedFile, 'utf8'));
  const { rows } = await client.query(`
    SELECT u.name, a.cached_balance
    FROM ledger.users AS u
    JOIN ledger.accounts AS a ON a.user_id = u.id
    WHERE u.email IN ('alice.demo@mini-ledger.test', 'bob.demo@mini-ledger.test')
    ORDER BY u.email
  `);
  console.log('Demo seed committed. Wallet balances (paise):');
  for (const row of rows) console.log(`  ${row.name}: ${row.cached_balance}`);
} catch (error) {
  console.error('Demo seed failed:', error.message);
  process.exitCode = 1;
} finally {
  await client.end();
}
