// The HTTP layer. Every route is one database function call; there are no balance
// checks, fee calculations or ledger rules here. Rules live in the database.
import express from 'express';
import { callFunction } from './db.js';
import { demo } from './demo/routes.js';

export const app = express();
app.use(express.json());

// Wrap async handlers so a rejected promise reaches the error handler.
const route = (handler) => (req, res, next) => handler(req, res).catch(next);

// The browser sends one Idempotency-Key per user action; the database enforces it.
const keyOf = (req) => req.get('Idempotency-Key') ?? null;
const intOrNull = (value) => (value === undefined || value === '' ? null : value);

// ---- wallets ---------------------------------------------------------------------

app.get('/api/wallets', route(async (req, res) => {
  const rows = await callFunction('app',
    'SELECT * FROM ledger.list_wallets($1, $2)',
    [req.query.search ?? null, req.query.limit ?? 50]);
  res.json(rows);
}));

app.post('/api/wallets', route(async (req, res) => {
  const { name, email } = req.body ?? {};
  const [row] = await callFunction('app',
    'SELECT ledger.create_user_with_wallet($1, $2) AS user_id', [name, email]);
  res.status(201).json(row);
}));

app.get('/api/wallets/:accountId/balance', route(async (req, res) => {
  const [row] = await callFunction('app',
    'SELECT ledger.get_balance($1) AS balance', [req.params.accountId]);
  res.json(row);
}));

app.get('/api/wallets/:accountId/history', route(async (req, res) => {
  const { cursor_created_at, cursor_id, limit } = req.query;
  const rows = await callFunction('app',
    'SELECT * FROM ledger.get_history($1, $2, $3, $4)',
    [req.params.accountId, intOrNull(cursor_created_at), intOrNull(cursor_id), limit ?? 20]);
  // The database says whether more rows exist (has_more on every row). Hand the client
  // the cursor for the next page: the position of the last row returned.
  const last = rows.at(-1);
  res.json({
    entries: rows,
    next_cursor: last?.has_more ? { cursor_created_at: last.created_at, cursor_id: last.entry_id } : null,
  });
}));

// ---- money movement (each needs an Idempotency-Key header) ----------------------------

app.post('/api/top-ups', route(async (req, res) => {
  const { wallet_account_id, amount } = req.body ?? {};
  const [row] = await callFunction('app',
    'SELECT ledger.top_up($1, $2, $3) AS transaction_id', [wallet_account_id, amount, keyOf(req)]);
  res.status(201).json(row);
}));

app.post('/api/withdrawals', route(async (req, res) => {
  const { wallet_account_id, amount } = req.body ?? {};
  const [row] = await callFunction('app',
    'SELECT ledger.withdraw($1, $2, $3) AS transaction_id', [wallet_account_id, amount, keyOf(req)]);
  res.status(201).json(row);
}));

app.post('/api/transfers', route(async (req, res) => {
  const { sender_account_id, recipient_account_id, amount } = req.body ?? {};
  const [row] = await callFunction('app',
    'SELECT ledger.transfer($1, $2, $3, $4) AS transaction_id',
    [sender_account_id, recipient_account_id, amount, keyOf(req)]);
  res.status(201).json(row);
}));

app.post('/api/refunds', route(async (req, res) => {
  const { original_transaction_id, amount } = req.body ?? {};
  const [row] = await callFunction('app',
    'SELECT ledger.refund($1, $2, $3) AS transaction_id',
    [original_transaction_id, amount, keyOf(req)]);
  res.status(201).json(row);
}));

app.get('/api/fee', route(async (req, res) => {
  const [row] = await callFunction('app', 'SELECT ledger.calculate_fee($1) AS fee', [req.query.amount]);
  res.json(row);
}));

// ---- admin (separate database login) ------------------------------------------------

app.post('/api/accounts/:accountId/freeze', route(async (req, res) => {
  const [row] = await callFunction('admin',
    'SELECT ledger.freeze_account($1) AS account_id', [req.params.accountId]);
  res.json(row);
}));

app.post('/api/accounts/:accountId/unfreeze', route(async (req, res) => {
  const [row] = await callFunction('admin',
    'SELECT ledger.unfreeze_account($1) AS account_id', [req.params.accountId]);
  res.json(row);
}));

app.get('/api/reconciliation', route(async (req, res) => {
  const [row] = await callFunction('admin', 'SELECT ledger.reconciliation_summary() AS healthy');
  res.json(row);
}));

app.get('/api/reconciliation/issues', route(async (req, res) => {
  res.json(await callFunction('admin', 'SELECT * FROM ledger.reconciliation_issues()'));
}));

app.use('/api/demo', demo);

app.get('/api/health', (req, res) => res.json({ ok: true }));

// ---- errors ------------------------------------------------------------------------
// Translate database error codes into HTTP statuses. The message comes from the
// database, so rule wording stays in one place.
app.use((error, req, res, next) => {
  void next;
  let status = 500;
  if (error.status) status = error.status;
  else if (error.code === 'P1001') status = /already in progress/.test(error.message) ? 409 : 422;
  else if (error.code === '42501') status = 403;        // permission denied
  else if (error.code === '40P01' || error.code === '40001') status = 409; // deadlock / serialization
  else if (error.code?.startsWith('22')) status = 400;  // bad input shape (not a number, too big)

  if (status === 500) console.error(error);
  res.status(status).json({
    error: status === 500 ? 'internal error' : error.message,
    code: error.code ?? null,
  });
});
