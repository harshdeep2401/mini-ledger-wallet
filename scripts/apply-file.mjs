// Applies ONE sql file in a transaction, without dropping anything.
//   node --env-file=.env scripts/apply-file.mjs db/09_wallet_directory.sql
// Use it to add a new numbered db/ file to an existing database without a reset
// (db:apply re-runs every file, and the older ones are not safe to run twice).
import { readFile } from 'node:fs/promises';
import pg from 'pg';

const file = process.argv[2];
if (!file || !process.env.DATABASE_URL) {
  console.error('Usage: node --env-file=.env scripts/apply-file.mjs <file.sql>');
  process.exit(1);
}

const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();
try {
  await client.query('BEGIN');
  await client.query(await readFile(file, 'utf8'));
  await client.query('COMMIT');
  console.log(`Applied ${file}`);
} catch (error) {
  await client.query('ROLLBACK');
  console.error(`Failed to apply ${file}:`, error.message);
  process.exitCode = 1;
} finally {
  await client.end();
}
