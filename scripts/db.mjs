// Applies the project's SQL files to the database in DATABASE_URL (loaded from .env).
//
//   npm run db:apply   run every numbered file in db/ (01_..., 02_..., ...) in order
//   npm run db:reset   DEVELOPMENT ONLY: drop the ledger schema, then run the files again
//
// Everything in one run happens inside ONE database transaction:
// if any file fails, nothing from that run is kept (and a reset's drop is undone too).
//
// Note: files are sent to PostgreSQL as plain SQL, so psql-only commands such as \i or
// \set won't work in them.

import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import readline from 'node:readline/promises';
import pg from 'pg';

const DB_DIR = path.join(import.meta.dirname, '..', 'db');
const RESET_FILE = 'reset-dev.sql';

async function main() {
  const command = process.argv[2];

  if (!process.env.DATABASE_URL) {
    console.error('DATABASE_URL is not set. Add it to the .env file in the project folder.');
    process.exit(1);
  }

  if (command === 'apply') {
    await runInOneTransaction(await numberedSqlFiles());
  } else if (command === 'reset') {
    if (!(await confirmReset())) {
      console.log('Reset cancelled.');
      return;
    }
    await runInOneTransaction([RESET_FILE, ...(await numberedSqlFiles())]);
  } else {
    console.error('Usage: node scripts/db.mjs apply | reset');
    process.exit(1);
  }
}

// Files like 01_schema.sql, 02_triggers.sql, sorted by their number.
async function numberedSqlFiles() {
  const names = await readdir(DB_DIR);
  return names.filter((name) => /^\d{2}_.*\.sql$/.test(name)).sort();
}

async function confirmReset() {
  console.log('WARNING: this permanently deletes all objects and data in the ledger schema.');
  const prompt = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await prompt.question('Type RESET ledger to continue: ');
  prompt.close();
  return answer.trim() === 'RESET ledger';
}

async function runInOneTransaction(files) {
  const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();

  let currentFile = null;
  let currentSql = '';
  try {
    await client.query('BEGIN');
    for (const file of files) {
      currentFile = file;
      currentSql = await readFile(path.join(DB_DIR, file), 'utf8');
      console.log(`Running db/${file}`);
      await client.query(currentSql);
    }
    // Deferred checks (like the balance trigger in Phase 3) run here, at COMMIT.
    currentFile = null;
    await client.query('COMMIT');
    console.log('Done. All changes committed.');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    printError(error, currentFile, currentSql);
    console.error('Rolled back: nothing from this run was saved.');
    process.exitCode = 1;
  } finally {
    await client.end();
  }
}

// Shows the PostgreSQL error, plus the file and line it came from when known.
function printError(error, file, sql) {
  console.error('\nERROR:', error.message);
  if (file && error.position) {
    const line = sql.slice(0, Number(error.position)).split('\n').length;
    console.error(`  at db/${file}, line ${line}`);
  } else if (file) {
    console.error(`  while running db/${file}`);
  } else {
    console.error('  at COMMIT (a deferred check failed)');
  }
  if (error.detail) console.error('  detail:', error.detail);
  if (error.hint) console.error('  hint:', error.hint);
}

await main();
