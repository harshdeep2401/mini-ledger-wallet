// The HTTP layer. Every route is one database function call; there are no balance
// checks, fee calculations or ledger rules here. Rules live in the database.
import express from 'express';
import { callFunction } from './db.js';
import { demo } from './demo/routes.js';
import { admin, requireAdmin } from './admin.js';
import { tokenOf } from './token.js';

export const app = express();
app.use(express.json());

// Wrap async handlers so a rejected promise reaches the error handler.
const route = (handler) => (req, res, next) => handler(req, res).catch(next);

// The browser sends one Idempotency-Key per user action; the database enforces it.
const keyOf = (req) => req.get('Idempotency-Key') ?? null;
const intOrNull = (value) => (value === undefined || value === '' ? null : value);

// ---- log in (ledger_web) -------------------------------------------------------------
// The browser keeps the session token and sends it as "Authorization: Bearer <token>".
// The server never decides who the user is: it hands the token to the database.

app.post('/api/auth/sign-up', route(async (req, res) => {
  const { name, email, password } = req.body ?? {};
  const [row] = await callFunction('web', 'SELECT * FROM ledger.sign_up($1, $2, $3)', [name, email, password]);
  res.status(201).json(row);
}));

app.post('/api/auth/log-in', route(async (req, res) => {
  const { email, password } = req.body ?? {};
  const [row] = await callFunction('web', 'SELECT * FROM ledger.log_in($1, $2)', [email, password]);
  // A failed log-in is a returned value (so the failure count commits), not an exception.
  if (row.error) return res.status(401).json({ error: row.error, code: 'P1002' });
  res.json({ token: row.token, expires_at: row.expires_at });
}));

app.post('/api/auth/log-out', route(async (req, res) => {
  await callFunction('web', 'SELECT ledger.log_out($1)', [tokenOf(req)]);
  res.status(204).end();
}));

// ---- the logged-in user's wallet (ledger_web) ---------------------------------------

app.get('/api/me', route(async (req, res) => {
  const [row] = await callFunction('web', 'SELECT * FROM ledger.my_wallet($1)', [tokenOf(req)]);
  res.json(row);
}));

app.get('/api/me/history', route(async (req, res) => {
  const { cursor_created_at, cursor_id, limit } = req.query;
  const rows = await callFunction('web',
    'SELECT * FROM ledger.my_history($1, $2, $3, $4)',
    [tokenOf(req), intOrNull(cursor_created_at), intOrNull(cursor_id), limit ?? 20]);
  // The database says whether more rows exist (has_more on every row). Hand the client
  // the cursor for the next page: the position of the last row returned.
  const last = rows.at(-1);
  res.json({
    entries: rows,
    next_cursor: last?.has_more ? { cursor_created_at: last.created_at, cursor_id: last.entry_id } : null,
  });
}));

app.get('/api/me/recipients', route(async (req, res) => {
  res.json(await callFunction('web',
    'SELECT * FROM ledger.find_recipients($1, $2, $3)',
    [tokenOf(req), req.query.search ?? null, req.query.limit ?? 10]));
}));

// Money movement: each needs an Idempotency-Key header. There is no "from" field:
// the database takes the source wallet from the session token.

app.post('/api/me/top-ups', route(async (req, res) => {
  const [row] = await callFunction('web',
    'SELECT ledger.my_top_up($1, $2, $3) AS transaction_id', [tokenOf(req), req.body?.amount, keyOf(req)]);
  res.status(201).json(row);
}));

app.post('/api/me/withdrawals', route(async (req, res) => {
  const [row] = await callFunction('web',
    'SELECT ledger.my_withdraw($1, $2, $3) AS transaction_id', [tokenOf(req), req.body?.amount, keyOf(req)]);
  res.status(201).json(row);
}));

app.post('/api/me/transfers', route(async (req, res) => {
  const { recipient_account_id, amount } = req.body ?? {};
  const [row] = await callFunction('web',
    'SELECT ledger.my_transfer($1, $2, $3, $4) AS transaction_id',
    [tokenOf(req), recipient_account_id, amount, keyOf(req)]);
  res.status(201).json(row);
}));

app.post('/api/me/refunds', route(async (req, res) => {
  const { original_transaction_id, amount } = req.body ?? {};
  const [row] = await callFunction('web',
    'SELECT ledger.my_refund($1, $2, $3, $4) AS transaction_id',
    [tokenOf(req), original_transaction_id, amount, keyOf(req)]);
  res.status(201).json(row);
}));

app.get('/api/fee', route(async (req, res) => {
  const [row] = await callFunction('web', 'SELECT ledger.calculate_fee($1) AS fee', [req.query.amount]);
  res.json(row);
}));

// ---- admin -------------------------------------------------------------------------
// Admin log-in, the admin dashboard and the demo console. Every admin route checks the
// admin session token in the database first (see server/admin.js).

app.use('/api/admin', admin);
app.use('/api/demo', requireAdmin, demo);

app.get('/api/health', (req, res) => res.json({ ok: true }));

// ---- errors ------------------------------------------------------------------------
// Translate database error codes into HTTP statuses. The message comes from the
// database, so rule wording stays in one place.
app.use((error, req, res, next) => {
  void next;
  let status = 500;
  if (error.status) status = error.status;
  else if (error.code === 'P1002') status = 401;        // not logged in / session expired
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
