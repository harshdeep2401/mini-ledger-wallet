// The demo engine: a "run" is a scripted scenario that the presenter plays one step at a
// time. Money still moves only through the ordinary database functions; this file just
// calls them in a fixed order, measures them, and reports what the database said.
import { randomUUID } from 'node:crypto';
import { callFunction, pools } from '../db.js';
import { scenarios } from './scenarios.js';

const runs = new Map();
const MAX_RUNS = 50;
const ms = (start) => Math.round((performance.now() - start) * 10) / 10;

// Friendly names for each function's arguments, so the screen can show "Input" as
// name: value pairs, and what each function returns.
const FUNCTIONS = {
  create_user_with_wallet: { args: ['name', 'email'], returns: 'user id' },
  list_wallets: { args: ['search', 'limit'], returns: 'wallet rows' },
  top_up: { args: ['wallet_account_id', 'amount_paise', 'idempotency_key'], returns: 'transaction id' },
  withdraw: { args: ['wallet_account_id', 'amount_paise', 'idempotency_key'], returns: 'transaction id' },
  transfer: { args: ['sender_account_id', 'recipient_account_id', 'amount_paise', 'idempotency_key'], returns: 'transaction id' },
  refund: { args: ['original_transaction_id', 'amount_paise', 'idempotency_key'], returns: 'transaction id' },
  calculate_fee: { args: ['amount_paise'], returns: 'fee in paise' },
  freeze_account: { args: ['account_id'], returns: 'account id' },
  unfreeze_account: { args: ['account_id'], returns: 'account id' },
  reconciliation_issues: { args: [], returns: 'list of problems' },
  get_balance: { args: ['account_id'], returns: 'balance in paise' },
};

// A single-value result is shown as the bare value; anything else as the rows.
const shapeOutput = (rows) =>
  rows.length === 1 && Object.keys(rows[0]).length === 1 ? Object.values(rows[0])[0] : rows;

// ---- helpers handed to scenario steps ------------------------------------------------
function makeHelpers(run, trace) {
  // Calls one database function and records its name, login and time in the trace.
  async function call(role, fn, sql, params) {
    const start = performance.now();
    const meta = FUNCTIONS[fn] ?? { args: [], returns: '' };
    const entry = {
      kind: 'function',
      function: `ledger.${fn}`,
      role: role === 'app' ? 'ledger_app' : 'ledger_admin',
      input: Object.fromEntries(meta.args.map((name, i) => [name, params[i] ?? null])),
      returns: meta.returns,
    };
    try {
      const rows = await callFunction(role, sql, params);
      entry.output = { ok: true, value: shapeOutput(rows) };
      return rows;
    } catch (error) {
      entry.output = { ok: false, code: error.code ?? null, message: error.message };
      throw error;
    } finally {
      entry.ms = ms(start);
      trace.push(entry);
    }
  }
  const key = (label) => `demo-${run.id}-${label}`;
  return {
    call,
    key,
    topUp: async (account, amount, label) =>
      (await call('app', 'top_up', 'SELECT ledger.top_up($1,$2,$3) AS id', [account, amount, key(label)]))[0].id,
    withdraw: async (account, amount, label) =>
      (await call('app', 'withdraw', 'SELECT ledger.withdraw($1,$2,$3) AS id', [account, amount, key(label)]))[0].id,
    transfer: async (from, to, amount, label) =>
      (await call('app', 'transfer', 'SELECT ledger.transfer($1,$2,$3,$4) AS id', [from, to, amount, key(label)]))[0].id,
    transferWithKey: async (from, to, amount, fullKey) =>
      (await call('app', 'transfer', 'SELECT ledger.transfer($1,$2,$3,$4) AS id', [from, to, amount, fullKey]))[0].id,
    refund: async (original, amount, label) =>
      (await call('app', 'refund', 'SELECT ledger.refund($1,$2,$3) AS id', [original, amount, key(label)]))[0].id,
    fee: async (amount) =>
      (await call('app', 'calculate_fee', 'SELECT ledger.calculate_fee($1) AS fee', [amount]))[0].fee,
    freeze: (account) => call('admin', 'freeze_account', 'SELECT ledger.freeze_account($1)', [account]),
    unfreeze: (account) => call('admin', 'unfreeze_account', 'SELECT ledger.unfreeze_account($1)', [account]),
    issues: () => call('admin', 'reconciliation_issues', 'SELECT * FROM ledger.reconciliation_issues()', []),

    // A fixed attack as a chosen database role, on the owner login. ALWAYS rolled back.
    // Resolves with the database's error, or { survived: true } if nothing stopped it.
    async attack(role, statements) {
      const start = performance.now();
      const client = await pools.demo.connect();
      const entry = {
        kind: 'sql',
        function: 'raw SQL (no ledger function)',
        role,
        input: { statements: statements.map((t) => t.replace(/\s+/g, ' ').trim()) },
        returns: 'rolled back afterwards, nothing is saved',
      };
      try {
        await client.query('BEGIN');
        await client.query(`SET LOCAL ROLE ${role}`); // role is a fixed literal from scenarios.js
        for (const statement of statements) await client.query(statement);
        entry.output = { ok: true, value: 'every statement ran without an error' };
        return { survived: true, ms: ms(start) };
      } catch (error) {
        entry.output = { ok: false, code: error.code ?? null, message: error.message };
        return { survived: false, code: error.code, message: error.message, ms: ms(start) };
      } finally {
        entry.ms = ms(start);
        trace.push(entry);
        await client.query('ROLLBACK').catch(() => {});
        client.release();
      }
    },

    // A fixed write on the owner login that is COMMITTED (used only by the tamper demo).
    async ownerWrite(sql, params) {
      const start = performance.now();
      const client = await pools.demo.connect();
      const entry = {
        kind: 'sql', function: 'raw SQL (no ledger function)', role: 'ledger_owner',
        input: { statement: sql, parameters: params }, returns: 'committed',
      };
      try {
        await client.query('BEGIN');
        await client.query('SET LOCAL ROLE ledger_owner');
        await client.query(sql, params);
        await client.query('COMMIT');
        entry.output = { ok: true, value: 'statement committed' };
      } catch (error) {
        await client.query('ROLLBACK').catch(() => {});
        entry.output = { ok: false, code: error.code ?? null, message: error.message };
        throw error;
      } finally {
        entry.ms = ms(start);
        trace.push(entry);
        client.release();
      }
    },
  };
}

// ---- reads that are not part of the story (not shown in the trace) -------------------
async function overview(ids) {
  const rows = await callFunction('app', 'SELECT * FROM ledger.account_overview($1)', [ids]);
  return rows.map((r) => ({ ...r, account_id: Number(r.account_id), balance: Number(r.balance) }));
}

async function legsOf(transactionId) {
  const rows = await callFunction('app', 'SELECT * FROM ledger.get_transaction($1)', [transactionId]);
  const legs = rows.map((r) => ({
    account_id: Number(r.account_id), label: r.account_label, direction: r.direction, amount: Number(r.amount),
  }));
  const sum = (d) => legs.filter((l) => l.direction === d).reduce((t, l) => t + l.amount, 0);
  return {
    transaction_id: Number(transactionId),
    type: rows[0]?.type,
    reverses_transaction_id: rows[0]?.reverses_transaction_id ?? null,
    legs,
    debits: sum('debit'),
    credits: sum('credit'),
  };
}

export async function ledgerHealth() {
  const start = performance.now();
  const [row] = await callFunction('admin', 'SELECT ledger.reconciliation_summary() AS healthy');
  return { healthy: row.healthy, ms: ms(start) };
}

const watchedIds = (run, keys) => keys.map((k) => run.ctx[k].id);

// ---- public API ------------------------------------------------------------------------
export function listScenarios() {
  return scenarios.map(({ id, group, title, description, steps }) => ({
    id, group, title, description, step_count: steps.length,
  }));
}

export async function startRun(scenarioId) {
  const scenario = scenarios.find((s) => s.id === scenarioId);
  if (!scenario) throw Object.assign(new Error('unknown scenario'), { status: 404 });

  if (runs.size >= MAX_RUNS) runs.delete(runs.keys().next().value);
  const run = { id: randomUUID().slice(0, 8), scenario, next: 0, ctx: {}, state: {} };
  runs.set(run.id, run);

  // Setup creates fresh wallets, so the numbers on screen are the same every time.
  const h = makeHelpers(run, []);
  const tag = `${run.id}-${Math.random().toString(36).slice(2, 6)}`;
  for (const person of scenario.people) {
    const email = `${person.name.toLowerCase()}-${tag}@demo.mini-ledger.test`;
    await h.call('app', 'create_user_with_wallet', 'SELECT ledger.create_user_with_wallet($1,$2)', [person.name, email]);
    const [wallet] = await h.call('app', 'list_wallets', 'SELECT * FROM ledger.list_wallets($1, 1)', [email]);
    run.ctx[person.key] = { id: Number(wallet.account_id), name: person.name };
    if (person.funding > 0) await h.topUp(run.ctx[person.key].id, person.funding, `fund-${person.key}`);
  }

  const watch = [...new Set(scenario.steps.flatMap((s) => s.watch))];
  return {
    run_id: run.id,
    scenario: { id: scenario.id, title: scenario.title, description: scenario.description },
    steps: scenario.steps.map((s) => ({ title: s.title, say: s.say, expect: s.expect })),
    accounts: await overview(watchedIds(run, watch)),
  };
}

export async function nextStep(runId) {
  const run = runs.get(runId);
  if (!run) throw Object.assign(new Error('run not found (start the scenario again)'), { status: 404 });
  const step = run.scenario.steps[run.next];
  if (!step) throw Object.assign(new Error('scenario finished'), { status: 409 });
  const index = run.next++;

  const trace = [];
  const h = makeHelpers(run, trace);
  const ids = watchedIds(run, step.watch);
  const before = await overview(ids);

  let outcome = 'accepted';
  let error = null;
  let result = {};
  const start = performance.now();
  try {
    result = (await step.run(h, run.ctx, run.state)) ?? {};
    if (result.survived === false) { outcome = 'rejected'; error = { code: result.code, message: result.message }; }
    if (result.survived === true) outcome = 'accepted';
  } catch (e) {
    outcome = 'rejected';
    error = { code: e.code ?? null, message: e.message };
  }
  const total_ms = ms(start);

  const [after, transaction] = await Promise.all([
    overview(ids),
    result.transactionId ? legsOf(result.transactionId) : null,
  ]);
  if (result.transactionId) run.state.last = result.transactionId;

  const expectHealthy = step.expectHealthy ?? true;
  return {
    index,
    title: step.title,
    expect: step.expect,
    outcome,
    outcome_as_expected: outcome === step.expect,
    error,
    notes: result.notes ?? [],
    rows: result.rows ?? [],
    transaction,
    before,
    after,
    trace,
    total_ms,
    expect_healthy: expectHealthy,
    finished: run.next >= run.scenario.steps.length,
  };
}

// Leaving a scenario early must not leave the tamper demo's corrupted balance behind.
export async function abortRun(runId) {
  const run = runs.get(runId);
  if (!run) return { ok: true };
  runs.delete(runId);
  if (run.state.tampered) {
    const h = makeHelpers(run, []);
    await h.ownerWrite('UPDATE ledger.accounts SET cached_balance = $2 WHERE id = $1', [
      run.state.tampered.id, run.state.tampered.original,
    ]);
    return { ok: true, repaired: true };
  }
  return { ok: true };
}
