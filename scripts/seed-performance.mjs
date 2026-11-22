// Deterministic performance seed. Every monetary operation calls a ledger
// operation function, and each batch commits independently so a failed run can
// be safely resumed with the same idempotency keys.
import pg from 'pg';

const WALLET_COUNT = 1_000;
const TRANSFER_COUNT = 120_000;
const TRANSFERS_PER_WITHDRAWAL = 20;
const BATCH_SIZE = 100;
const INITIAL_TOPUP = 1_000_000; // ₹10,000 per wallet, in paise.
const EMAIL_PREFIX = 'perf-wallet-';
const KEY_PREFIX = 'perf-v1';

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL is not set. Add it to the .env file in the project folder.');
  process.exit(1);
}

const client = new pg.Client({ connectionString: process.env.DATABASE_URL });

function walletEmail(index) {
  return `${EMAIL_PREFIX}${String(index).padStart(4, '0')}@mini-ledger.test`;
}

function chunks(items, size) {
  const result = [];
  for (let start = 0; start < items.length; start += size) {
    result.push(items.slice(start, start + size));
  }
  return result;
}

async function commitBatch(label, work) {
  await client.query('BEGIN');
  try {
    await work();
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw new Error(`${label} batch failed: ${error.message}`, { cause: error });
  }
}

async function createMissingUsers(emails) {
  const { rows: existing } = await client.query(
    'SELECT email FROM ledger.users WHERE email = ANY($1::text[])',
    [emails],
  );
  const existingEmails = new Set(existing.map((row) => row.email));
  const missing = emails
    .map((email, index) => ({ email, index }))
    .filter(({ email }) => !existingEmails.has(email));

  for (const batch of chunks(missing, BATCH_SIZE)) {
    await commitBatch('user creation', async () => {
      const values = [];
      const bindings = [];
      for (const { email, index } of batch) {
        const offset = bindings.length;
        values.push(`($${offset + 1}::text, $${offset + 2}::text)`);
        bindings.push(`Performance Wallet ${String(index + 1).padStart(4, '0')}`, email);
      }
      await client.query(
        `SELECT ledger.create_user_with_wallet(v.name, v.email)
         FROM (VALUES ${values.join(', ')}) AS v(name, email)`,
        bindings,
      );
    });
  }
}

async function callBatches(label, rows, columns, functionName) {
  let completed = 0;
  for (const batch of chunks(rows, BATCH_SIZE)) {
    await commitBatch(label, async () => {
      const values = [];
      const bindings = [];
      for (const row of batch) {
        const fields = row.map((value, columnIndex) => {
          bindings.push(value);
          const type = columns[columnIndex].type;
          return `$${bindings.length}::${type}`;
        });
        values.push(`(${fields.join(', ')})`);
      }
      const projection = columns.map((column) => `v.${column.name}`).join(', ');
      await client.query(
        `SELECT ledger.${functionName}(${projection})
         FROM (VALUES ${values.join(', ')}) AS v(${columns.map((column) => column.name).join(', ')})`,
        bindings,
      );
    });
    completed += batch.length;
    if (completed % 10_000 === 0 || completed === rows.length) {
      console.log(`${label}: ${completed.toLocaleString()} / ${rows.length.toLocaleString()}`);
    }
  }
}

try {
  await client.connect();

  const emails = Array.from({ length: WALLET_COUNT }, (_, index) => walletEmail(index));
  await createMissingUsers(emails);

  const { rows: walletRows } = await client.query(
    `SELECT u.email, a.id AS wallet_id
     FROM ledger.users AS u
     JOIN ledger.accounts AS a ON a.user_id = u.id
     WHERE u.email = ANY($1::text[])
     ORDER BY u.email`,
    [emails],
  );
  if (walletRows.length !== WALLET_COUNT) {
    throw new Error(`expected ${WALLET_COUNT} performance wallets, found ${walletRows.length}`);
  }
  const wallets = new Map(walletRows.map((row) => [row.email, row.wallet_id]));

  const topups = walletRows.map((row, index) => [
    row.wallet_id,
    INITIAL_TOPUP,
    `${KEY_PREFIX}-topup-${String(index).padStart(4, '0')}`,
  ]);
  await callBatches(
    'Top-ups',
    topups,
    [
      { name: 'wallet_id', type: 'bigint' },
      { name: 'amount', type: 'bigint' },
      { name: 'idempotency_key', type: 'text' },
    ],
    'top_up',
  );

  const transfers = [];
  const withdrawals = [];
  for (let index = 0; index < TRANSFER_COUNT; index += 1) {
    const senderIndex = index % WALLET_COUNT;
    // Offset is always 1..999, so a transfer can never be self-directed.
    const recipientOffset = 1 + ((index * 37) % (WALLET_COUNT - 1));
    const recipientIndex = (senderIndex + recipientOffset) % WALLET_COUNT;
    const amount = 1_000 + ((index * 7_919) % 4_001); // ₹10.00–₹50.00.
    transfers.push([
      wallets.get(walletEmail(senderIndex)),
      wallets.get(walletEmail(recipientIndex)),
      amount,
      `${KEY_PREFIX}-transfer-${String(index).padStart(6, '0')}`,
    ]);

    if ((index + 1) % TRANSFERS_PER_WITHDRAWAL === 0) {
      withdrawals.push([
        wallets.get(walletEmail(senderIndex)),
        5_000, // ₹50.00; six withdrawals at most per wallet.
        `${KEY_PREFIX}-withdraw-${String(index).padStart(6, '0')}`,
      ]);
    }
  }

  // Every wallet starts with ₹10,000. At most 120 transfers × ₹51 including
  // the fee, plus six ₹50 withdrawals, can debit one wallet; this is below
  // ₹6,420, before any incoming transfers.
  await callBatches(
    'Transfers',
    transfers,
    [
      { name: 'sender_wallet_id', type: 'bigint' },
      { name: 'recipient_wallet_id', type: 'bigint' },
      { name: 'amount', type: 'bigint' },
      { name: 'idempotency_key', type: 'text' },
    ],
    'transfer',
  );
  await callBatches(
    'Withdrawals',
    withdrawals,
    [
      { name: 'wallet_id', type: 'bigint' },
      { name: 'amount', type: 'bigint' },
      { name: 'idempotency_key', type: 'text' },
    ],
    'withdraw',
  );

  const { rows: verification } = await client.query(`
    SELECT
      ledger.reconciliation_summary() AS healthy,
      (SELECT COUNT(*) FROM ledger.transactions) AS transaction_count,
      (SELECT COUNT(*) FROM ledger.ledger_entries) AS entry_count,
      (SELECT COUNT(*) FROM ledger.reconciliation_issues()) AS issue_count
  `);
  const result = verification[0];
  console.log(`Reconciliation healthy: ${result.healthy}`);
  console.log(`Transactions: ${Number(result.transaction_count).toLocaleString()}`);
  console.log(`Ledger entries: ${Number(result.entry_count).toLocaleString()}`);
  console.log(`Reconciliation issues: ${result.issue_count}`);
  if (!result.healthy || Number(result.issue_count) !== 0) {
    throw new Error('performance seed did not reconcile cleanly');
  }
} catch (error) {
  console.error('Performance seed failed:', error.message);
  process.exitCode = 1;
} finally {
  await client.end();
}
