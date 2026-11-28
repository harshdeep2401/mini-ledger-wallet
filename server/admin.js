// Admin routes (/api/admin/*). All go through the browser login (ledger_web) and the
// token-checked admin_* functions in db/13_admin_auth.sql, so the database decides
// who is an admin. Exceptions, each guarded by requireAdmin first:
//   * the live feed (one shared LISTEN connection, reads as ledger_admin),
//   * the traffic simulator (acts as ledger_app),
//   * the demo console (/api/demo, mounted in app.js).
import express from 'express';
import { callFunction } from './db.js';
import { eventsRoute } from './live.js';
import * as simulator from './simulator.js';
import { tokenOf } from './token.js';

export const admin = express.Router();
const route = (handler) => (req, res, next) => handler(req, res, next).catch(next);

// Asks the database whether the token belongs to a logged-in admin (P1002 -> 401).
export const requireAdmin = route(async (req, res, next) => {
  await callFunction('web', 'SELECT * FROM ledger.admin_me($1)', [tokenOf(req)]);
  next();
});

// ---- admin log-in ------------------------------------------------------------------

admin.post('/auth/sign-up', route(async (req, res) => {
  const { name, email, password, invite_code } = req.body ?? {};
  const [row] = await callFunction('web',
    'SELECT * FROM ledger.admin_sign_up($1, $2, $3, $4)', [name, email, password, invite_code]);
  res.status(201).json(row);
}));

admin.post('/auth/log-in', route(async (req, res) => {
  const { email, password } = req.body ?? {};
  const [row] = await callFunction('web', 'SELECT * FROM ledger.admin_log_in($1, $2)', [email, password]);
  // A failed log-in is a returned value (so the failure count commits), not an exception.
  if (row.error) return res.status(401).json({ error: row.error, code: 'P1002' });
  res.json({ token: row.token, expires_at: row.expires_at });
}));

admin.post('/auth/log-out', route(async (req, res) => {
  await callFunction('web', 'SELECT ledger.admin_log_out($1)', [tokenOf(req)]);
  res.status(204).end();
}));

admin.get('/me', route(async (req, res) => {
  const [row] = await callFunction('web', 'SELECT * FROM ledger.admin_me($1)', [tokenOf(req)]);
  res.json(row);
}));

// ---- dashboard reads and actions (one token-checked function each) -------------------

admin.get('/stats', route(async (req, res) => {
  const [row] = await callFunction('web', 'SELECT * FROM ledger.admin_stats($1)', [tokenOf(req)]);
  res.json(row);
}));

admin.get('/feed', route(async (req, res) => {
  res.json(await callFunction('web',
    'SELECT * FROM ledger.admin_feed($1, $2, $3)', [tokenOf(req), req.query.limit ?? 30, null]));
}));

admin.get('/transactions/:id', route(async (req, res) => {
  res.json(await callFunction('web',
    'SELECT * FROM ledger.admin_transaction($1, $2)', [tokenOf(req), req.params.id]));
}));

admin.get('/transactions/:id/refunds', route(async (req, res) => {
  res.json(await callFunction('web',
    'SELECT * FROM ledger.admin_transaction_refunds($1, $2)', [tokenOf(req), req.params.id]));
}));

admin.get('/wallets', route(async (req, res) => {
  res.json(await callFunction('web',
    'SELECT * FROM ledger.admin_wallets($1, $2, $3)',
    [tokenOf(req), req.query.search ?? null, req.query.limit ?? 50]));
}));

admin.post('/wallets/:accountId/freeze', route(async (req, res) => {
  const [row] = await callFunction('web',
    'SELECT ledger.admin_freeze($1, $2) AS account_id', [tokenOf(req), req.params.accountId]);
  res.json(row);
}));

admin.post('/wallets/:accountId/unfreeze', route(async (req, res) => {
  const [row] = await callFunction('web',
    'SELECT ledger.admin_unfreeze($1, $2) AS account_id', [tokenOf(req), req.params.accountId]);
  res.json(row);
}));

admin.get('/reconciliation', route(async (req, res) => {
  const [row] = await callFunction('web', 'SELECT ledger.admin_reconciliation($1) AS healthy', [tokenOf(req)]);
  res.json(row);
}));

admin.get('/reconciliation/issues', route(async (req, res) => {
  res.json(await callFunction('web', 'SELECT * FROM ledger.admin_reconciliation_issues($1)', [tokenOf(req)]));
}));

// ---- live feed and simulator (admin token checked first) ---------------------------

admin.get('/events', requireAdmin, route(eventsRoute));

admin.get('/simulator', requireAdmin, (req, res) => res.json(simulator.status()));
admin.post('/simulator/start', requireAdmin, route(async (req, res) => res.json(await simulator.start(req.body?.rate))));
admin.post('/simulator/stop', requireAdmin, (req, res) => res.json(simulator.stop()));
