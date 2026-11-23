// Phase 11: concurrency demos. Each scenario opens several database connections and
// makes them race, then checks the outcome and prints PASS or FAIL.
//
//   npm run demo:setup          install the deliberately broken demo.* functions
//   npm run demo:teardown       remove them again
//   npm run demo:concurrency    run all three demos 5 times each
//   node --env-file=.env demos/concurrency.mjs <double-spend|deadlock|idempotency|all> [runs]
//
// Every run creates its own fresh demo users, so it can be repeated. Money is simulated.
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import pg from 'pg';

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL is not set. Add it to the .env file in the project folder.');
  process.exit(1);
}

const [command = 'all', runsArg = '5'] = process.argv.slice(2);
const RUNS = Number(runsArg);
const RUN_TAG = Date.now().toString(36);
// Set DEMO_VERBOSE=1 (the web console does) to print every statement a session sends
// (INPUT) and what it got back (OUTPUT), with the time since the run started.
const VERBOSE = process.env.DEMO_VERBOSE === '1';
let t0 = performance.now();
const stamp = () => `+${String(Math.round(performance.now() - t0)).padStart(5)} ms`;
const say = (text) => { if (VERBOSE) console.log(`  ${stamp()}  ${text}`); };
const rupees = (paise) => `₹${(Number(paise) / 100).toFixed(2)}`;

async function connect(label = 'setup') {
  const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  client.label = label;
  return client;
}

// Runs one statement and returns { ok, value } or { ok: false, code, message }.
async function attempt(client, text, values) {
  say(`[${client.label}] INPUT   ${text.replace(/\s+/g, ' ')}   params = ${JSON.stringify(values)}`);
  try {
    const { rows } = await client.query(text, values);
    const value = Object.values(rows[0])[0];
    say(`[${client.label}] OUTPUT  returned ${value}`);
    return { ok: true, value };
  } catch (error) {
    say(`[${client.label}] OUTPUT  ERROR ${error.code}: ${error.message}`);
    return { ok: false, code: error.code, message: error.message };
  }
}

// Creates a user with `paise` in the wallet; returns the wallet account id.
async function newWallet(admin, label, paise) {
  const tag = `${RUN_TAG}-${label}-${Math.random().toString(36).slice(2, 6)}`;
  const user = await admin.query(
    'SELECT ledger.create_user_with_wallet($1, $2) AS id',
    [`Conc ${label}`, `conc-${tag}@mini-ledger.test`],
  );
  const wallet = await admin.query('SELECT id FROM ledger.accounts WHERE user_id = $1', [user.rows[0].id]);
  const accountId = wallet.rows[0].id;
  await admin.query('SELECT ledger.top_up($1, $2, $3)', [accountId, paise, `conc-${tag}-fund`]);
  say(`[setup] created wallet ${accountId} ("${label}") and topped it up with ${rupees(paise)}`);
  return accountId;
}

async function balanceOf(admin, accountId) {
  const { rows } = await admin.query('SELECT ledger.get_balance($1) AS balance', [accountId]);
  say(`[setup] INPUT   SELECT ledger.get_balance(${accountId})   ->   OUTPUT  ${rupees(rows[0].balance)}`);
  return Number(rows[0].balance);
}

async function reconciliationHealthy(admin) {
  const { rows } = await admin.query('SELECT ledger.reconciliation_summary() AS healthy');
  say(`[setup] INPUT   SELECT ledger.reconciliation_summary()   ->   OUTPUT  ${rows[0].healthy}`);
  return rows[0].healthy;
}

function report(name, checks) {
  const pass = checks.every((c) => c.ok);
  console.log(`  ${pass ? 'PASS' : 'FAIL'}  ${name}`);
  for (const c of checks) console.log(`        ${c.ok ? '✓' : '✗'} ${c.text}`);
  return pass;
}

// ---------------------------------------------------------------------------
// Demo 1: double-spend. Two ₹800 withdrawals race against a ₹1,000 wallet.
// ---------------------------------------------------------------------------
async function doubleSpend(admin, label, sql, extraArgs) {
  const wallet = await newWallet(admin, label, 100000);
  const clients = await Promise.all([connect('session 1'), connect('session 2')]);
  try {
    const results = await Promise.all(
      clients.map((client, i) => attempt(client, sql, [wallet, 80000, ...extraArgs(i)])),
    );
    return { wallet, results, balance: await balanceOf(admin, wallet) };
  } finally {
    await Promise.all(clients.map((c) => c.end()));
  }
}

async function runDoubleSpend(admin) {
  t0 = performance.now();
  console.log('Double-spend: two ₹800 withdrawals race against a ₹1,000 wallet');
  let allPass = true;

  say('--- BROKEN version: demo.withdraw_unsafe reads the balance, pauses 1 s, then writes (no lock) ---');
  const unsafe = await doubleSpend(
    admin, 'unsafe', 'SELECT demo.withdraw_unsafe($1, $2) AS id', () => [],
  );
  const unsafeOk = unsafe.results.filter((r) => r.ok).length;
  allPass &&= report('unsafe withdraw: both succeed (the bug)', [
    { ok: unsafeOk === 2, text: `${unsafeOk} of 2 withdrawals succeeded` },
    { ok: unsafe.balance === -60000, text: `wallet balance is ${rupees(unsafe.balance)} (should never be negative)` },
  ]);

  // The bug left a negative wallet. Repair it with a normal top-up (history is
  // append-only: we add a correcting entry, we do not delete anything).
  if (unsafe.balance < 0) {
    await admin.query('SELECT ledger.top_up($1, $2, $3)',
      [unsafe.wallet, -unsafe.balance, `conc-${RUN_TAG}-repair-${unsafe.wallet}`]);
  }

  say('--- REAL version: ledger.withdraw locks the wallet row first (SELECT ... FOR UPDATE) ---');
  const safe = await doubleSpend(
    admin, 'safe', 'SELECT ledger.withdraw($1, $2, $3) AS id', (i) => [`conc-${RUN_TAG}-ds-${i}-${Math.random()}`],
  );
  const safeOk = safe.results.filter((r) => r.ok).length;
  const refused = safe.results.find((r) => !r.ok);
  allPass &&= report('real withdraw: exactly one succeeds', [
    { ok: safeOk === 1, text: `${safeOk} of 2 withdrawals succeeded` },
    { ok: refused?.code === 'P1001' && /insufficient funds/.test(refused.message), text: `the other was refused: ${refused?.message ?? 'not refused'}` },
    { ok: safe.balance === 20000, text: `wallet balance is ${rupees(safe.balance)}` },
  ]);

  const healthy = await reconciliationHealthy(admin);
  allPass &&= report('ledger is healthy afterwards', [{ ok: healthy, text: `reconciliation_summary() = ${healthy}` }]);
  return allPass;
}

// ---------------------------------------------------------------------------
// Demo 2: deadlock. A->B and B->A transfers race each other.
// ---------------------------------------------------------------------------
async function runDeadlock(admin) {
  t0 = performance.now();
  console.log('Deadlock: A->B and B->A transfers race each other');
  let allPass = true;
  const a = await newWallet(admin, 'dl-a', 100000);
  const b = await newWallet(admin, 'dl-b', 100000);
  const clients = await Promise.all([connect('session 1'), connect('session 2')]);
  try {
    say('--- BROKEN version: demo.transfer_unordered locks the sender, pauses, then locks the recipient ---');
    say(`session 1 sends A(${a}) -> B(${b}); session 2 sends B -> A, so each ends up waiting for the other`);
    const unsafe = await Promise.all([
      attempt(clients[0], 'SELECT demo.transfer_unordered($1, $2, 10000) AS id', [a, b]),
      attempt(clients[1], 'SELECT demo.transfer_unordered($1, $2, 10000) AS id', [b, a]),
    ]);
    const deadlocked = unsafe.filter((r) => r.code === '40P01').length;
    const survived = unsafe.filter((r) => r.ok).length;
    allPass &&= report('unordered locking: PostgreSQL has to abort one', [
      { ok: deadlocked === 1, text: `${deadlocked} transfer aborted with 40P01 "deadlock detected"` },
      { ok: survived === 1, text: `${survived} transfer completed after the victim was aborted` },
    ]);

    say('--- REAL version: ledger.transfer always locks the lower account id first, so no cycle can form ---');
    const ROUNDS = 10;
    let safeFailures = 0;
    for (let round = 0; round < ROUNDS; round++) {
      const pair = await Promise.all([
        attempt(clients[0], 'SELECT ledger.transfer($1, $2, 1000, $3) AS id', [a, b, `conc-${RUN_TAG}-dl-${round}-ab-${Math.random()}`]),
        attempt(clients[1], 'SELECT ledger.transfer($1, $2, 1000, $3) AS id', [b, a, `conc-${RUN_TAG}-dl-${round}-ba-${Math.random()}`]),
      ]);
      safeFailures += pair.filter((r) => !r.ok).length;
    }
    allPass &&= report('real transfer: ordered locking never deadlocks', [
      { ok: safeFailures === 0, text: `${ROUNDS * 2} opposite transfers, ${safeFailures} failures` },
    ]);
  } finally {
    await Promise.all(clients.map((c) => c.end()));
  }
  const healthy = await reconciliationHealthy(admin);
  allPass &&= report('ledger is healthy afterwards', [{ ok: healthy, text: `reconciliation_summary() = ${healthy}` }]);
  return allPass;
}

// ---------------------------------------------------------------------------
// Demo 3: idempotency race. The same key arrives on several connections at once.
// ---------------------------------------------------------------------------
async function countTransactions(admin, key) {
  const { rows } = await admin.query('SELECT count(*) AS n FROM ledger.transactions WHERE idempotency_key = $1', [key]);
  return Number(rows[0].n);
}

async function runIdempotency(admin) {
  t0 = performance.now();
  console.log('Idempotency race: the same key sent from several connections at once');
  let allPass = true;
  const wallet = await newWallet(admin, 'idem', 1000);

  // Part 1, deterministic overlap: session A holds the key's transaction open
  // while session B arrives with the same key.
  say('--- Part 1: session A keeps its transaction open while session B sends the same key ---');
  const key1 = `conc-${RUN_TAG}-idem-open-${Math.random()}`;
  const [a, b] = await Promise.all([connect('session A'), connect('session B')]);
  try {
    await a.query('BEGIN');
    say('[session A] INPUT   BEGIN');
    const first = await attempt(a, 'SELECT ledger.top_up($1, 5000, $2) AS id', [wallet, key1]);
    const second = await attempt(b, 'SELECT ledger.top_up($1, 5000, $2) AS id', [wallet, key1]);
    await a.query('COMMIT');
    say('[session A] INPUT   COMMIT');
    const retry = await attempt(b, 'SELECT ledger.top_up($1, 5000, $2) AS id', [wallet, key1]);
    allPass &&= report('same key while the first request is still running', [
      { ok: first.ok, text: 'first request is inside its open transaction' },
      { ok: !second.ok && second.code === 'P1001' && /already in progress/.test(second.message), text: `second request fails fast: ${second.message}` },
      { ok: retry.ok && String(retry.value) === String(first.value), text: `retry after commit returns the same transaction id (${retry.value})` },
      { ok: (await countTransactions(admin, key1)) === 1, text: 'exactly 1 transaction exists for the key' },
    ]);
  } finally {
    await Promise.all([a.end(), b.end()]);
  }

  // Part 2, true race: eight connections fire the same key together.
  say('--- Part 2: eight sessions send the same key at the same instant ---');
  const key2 = `conc-${RUN_TAG}-idem-race-${Math.random()}`;
  const clients = await Promise.all(Array.from({ length: 8 }, (_, i) => connect(`session ${i + 1}`)));
  try {
    const results = await Promise.all(
      clients.map((c) => attempt(c, 'SELECT ledger.top_up($1, 5000, $2) AS id', [wallet, key2])),
    );
    const winners = new Set(results.filter((r) => r.ok).map((r) => String(r.value)));
    const unexpected = results.filter((r) => !r.ok && !/already in progress/.test(r.message));
    allPass &&= report('8 simultaneous requests with one key', [
      { ok: winners.size === 1, text: `${results.filter((r) => r.ok).length} succeeded, all with transaction id ${[...winners].join(',')}` },
      { ok: unexpected.length === 0, text: `${results.filter((r) => !r.ok).length} refused as "already in progress", no other errors` },
      { ok: (await countTransactions(admin, key2)) === 1, text: 'exactly 1 transaction exists for the key' },
    ]);
  } finally {
    await Promise.all(clients.map((c) => c.end()));
  }

  const balance = await balanceOf(admin, wallet);
  allPass &&= report('the money moved once per key', [{ ok: balance === 11000, text: `wallet balance is ${rupees(balance)} (₹10 start + two keys x ₹50)` }]);
  const healthy = await reconciliationHealthy(admin);
  allPass &&= report('ledger is healthy afterwards', [{ ok: healthy, text: `reconciliation_summary() = ${healthy}` }]);
  return allPass;
}

// ---------------------------------------------------------------------------
async function setup() {
  const client = await connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL ROLE ledger_owner');
    await client.query(await readFile(path.join(import.meta.dirname, 'sql', 'demo_functions.sql'), 'utf8'));
    await client.query('COMMIT');
    console.log('Installed demo.withdraw_unsafe and demo.transfer_unordered (owner-only).');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    await client.end();
  }
}

async function teardown() {
  const client = await connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL ROLE ledger_owner');
    await client.query('DROP SCHEMA IF EXISTS demo CASCADE');
    await client.query('COMMIT');
    console.log('Removed the demo schema.');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    await client.end();
  }
}

const scenarios = {
  'double-spend': runDoubleSpend,
  deadlock: runDeadlock,
  idempotency: runIdempotency,
};

async function main() {
  if (command === 'setup') return setup();
  if (command === 'teardown') return teardown();

  const names = command === 'all' ? Object.keys(scenarios) : [command];
  if (names.some((n) => !scenarios[n])) {
    console.error('Usage: concurrency.mjs setup | teardown | double-spend | deadlock | idempotency | all [runs]');
    process.exit(1);
  }

  const admin = await connect();
  const tally = {};
  try {
    for (let run = 1; run <= RUNS; run++) {
      console.log(`\n=== Run ${run} of ${RUNS} ===`);
      for (const name of names) {
        const pass = await scenarios[name](admin);
        tally[name] = (tally[name] ?? 0) + (pass ? 1 : 0);
      }
    }
  } finally {
    await admin.end();
  }

  console.log('\n=== Summary ===');
  let failed = false;
  for (const name of names) {
    console.log(`  ${name}: ${tally[name]} of ${RUNS} runs passed`);
    failed ||= tally[name] !== RUNS;
  }
  process.exitCode = failed ? 1 : 0;
}

main().catch((error) => {
  console.error('Concurrency demo failed:', error.message);
  process.exitCode = 1;
});
