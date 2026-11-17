// Runs every SQL test file in tests/ (in name order) against the database in DATABASE_URL.
//
//   npm run test:db
//
// This does NOT load the schema. Run `npm run db:apply` (or db:reset) first.
// A test file passes if it runs without error. Our tests signal failure with
// RAISE EXCEPTION 'TEST FAILED: ...', and each test wraps its work in
// BEGIN ... ROLLBACK, so nothing is left behind in the database.

import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import pg from 'pg';

const TESTS_DIR = path.join(import.meta.dirname, '..', 'tests');

async function main() {
  if (!process.env.DATABASE_URL) {
    console.error('DATABASE_URL is not set. Add it to the .env file in the project folder.');
    process.exit(1);
  }

  const files = (await readdir(TESTS_DIR)).filter((name) => name.endsWith('.sql')).sort();
  if (files.length === 0) {
    console.log('No test files found in tests/.');
    return;
  }

  const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
  // Print RAISE NOTICE messages (e.g. "TEST PASSED: ...") as they arrive.
  client.on('notice', (notice) => console.log(`    ${notice.message}`));
  await client.connect();

  let failed = 0;
  try {
    for (const file of files) {
      console.log(`tests/${file}`);
      try {
        await client.query(await readFile(path.join(TESTS_DIR, file), 'utf8'));
        console.log('  PASS\n');
      } catch (error) {
        failed += 1;
        console.log(`  FAIL: ${error.message}\n`);
        // The test stopped midway, so end its open transaction to leave nothing behind.
        await client.query('ROLLBACK').catch(() => {});
      }
    }
  } finally {
    await client.end();
  }

  console.log(`${files.length - failed} passed, ${failed} failed`);
  if (failed > 0) process.exitCode = 1;
}

await main();
