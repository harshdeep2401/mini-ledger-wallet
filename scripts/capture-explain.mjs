// Captures repeatable EXPLAIN evidence into docs/explain/*.txt.
// The no-index comparison drops the history index transactionally and rolls
// that DDL back, restoring the original state even if a query fails.
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import pg from 'pg';

const ROOT = path.join(import.meta.dirname, '..');
const QUERIES = path.join(ROOT, 'docs', 'explain', 'queries');
const OUTPUT = path.join(ROOT, 'docs', 'explain');
const REPEATS = 3;

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL is not set. Add it to the .env file in the project folder.');
  process.exit(1);
}

const client = new pg.Client({ connectionString: process.env.DATABASE_URL });

function renderPlan(label, rows) {
  const plan = rows.map((row) => row['QUERY PLAN']).join('\n');
  return `--- ${label} ---\n${plan}\n`;
}

async function capturePlan(filename, params = [], repeats = REPEATS) {
  const sql = await readFile(path.join(QUERIES, filename), 'utf8');
  const outputs = [];
  for (let run = 1; run <= repeats; run += 1) {
    const { rows } = await client.query(sql, params);
    outputs.push(renderPlan(`run ${run} of ${repeats}`, rows));
  }
  return outputs.join('\n');
}

async function save(name, contents) {
  await writeFile(path.join(OUTPUT, `${name}.txt`), contents, 'utf8');
  console.log(`Saved docs/explain/${name}.txt`);
}

try {
  await client.connect();
  await client.query('ANALYZE ledger.accounts');
  await client.query('ANALYZE ledger.transactions');
  await client.query('ANALYZE ledger.ledger_entries');

  const { rows: [account] } = await client.query(`
    SELECT a.id,
           (SELECT COUNT(*) FROM ledger.ledger_entries AS e WHERE e.account_id = a.id) AS entry_count
    FROM ledger.accounts AS a
    WHERE a.code = 'FEE_INCOME'
  `);
  if (!account) throw new Error('FEE_INCOME system account is missing');
  if (Number(account.entry_count) < 100_001) {
    throw new Error(
      `FEE_INCOME has ${account.entry_count} entries; the 100,000-row deep-page comparison needs at least 100,001. Run the performance seed first.`,
    );
  }

  const { rows: [cursor] } = await client.query(
    `SELECT created_at, id
     FROM ledger.ledger_entries
     WHERE account_id = $1
     ORDER BY created_at DESC, id DESC
     OFFSET 99999 LIMIT 1`,
    [account.id],
  );

  const setup = await client.query(await readFile(path.join(QUERIES, 'setup-facts.sql'), 'utf8'));
  await save('setup-facts', JSON.stringify(setup.rows, null, 2));

  await save('history-with-index', await capturePlan('history-indexed-page.sql', [account.id]));

  // Drop and analyze only in this transaction. The rollback restores the
  // history index before the script continues or exits.
  let withoutIndex;
  await client.query('BEGIN');
  try {
    await client.query('DROP INDEX IF EXISTS ledger.idx_ledger_entries_account_history');
    await client.query('ANALYZE ledger.ledger_entries');
    withoutIndex = await capturePlan('history-indexed-page.sql', [account.id]);
  } finally {
    await client.query('ROLLBACK');
  }
  await save('history-without-index', withoutIndex);

  await save('offset-deep-page', await capturePlan('history-offset-deep-page.sql', [account.id]));
  await save('keyset-page-1', await capturePlan('history-indexed-page.sql', [account.id]));
  await save('keyset-deep-page', await capturePlan(
    'history-keyset-deep-page.sql',
    [account.id, cursor.created_at, cursor.id],
  ));
  await save('balance-cached', await capturePlan('balance-cached.sql', [account.id]));
  await save('balance-recomputed', await capturePlan('balance-recomputed.sql', [account.id]));
  await save('reconciliation', await capturePlan('reconciliation.sql'));
} catch (error) {
  console.error('EXPLAIN capture failed:', error.message);
  process.exitCode = 1;
} finally {
  await client.end();
}
