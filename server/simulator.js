// Traffic simulator: pretends to be many users using the wallet at the same time.
//
// It is a CLIENT, not part of the ledger. It only calls the same database functions
// the Pay screen calls, as ledger_app. It never checks balances or computes fees
// itself: it sends plausible (and sometimes bad) requests and lets the database
// accept or reject them. Several requests are in flight at once, so the row locks,
// balance checks and idempotency keys are exercised for real.
import { randomUUID } from 'node:crypto';
import { callFunction } from './db.js';

const SIM_TAG = 'trafficsim';       // simulated users have emails like riya@trafficsim.example
const USER_COUNT = 30;
const MAX_IN_FLIGHT = 8;
const MAX_RUN_MS = 10 * 60 * 1000;  // stop by itself after 10 minutes
const NAMES = [
  'Aarav', 'Diya', 'Kabir', 'Meera', 'Rohan', 'Ananya', 'Vihaan', 'Isha', 'Arjun', 'Sara',
  'Dev', 'Priya', 'Neel', 'Tara', 'Kunal', 'Riya', 'Aditya', 'Zoya', 'Karan', 'Nisha',
  'Yash', 'Pooja', 'Om', 'Kiara', 'Samar', 'Leela', 'Ishaan', 'Mira', 'Varun', 'Asha',
];

const state = {
  running: false,
  starting: false,
  rate: 0,
  startedAt: null,
  wallets: [],          // account ids of simulated users
  inFlight: 0,
  counts: { attempted: 0, accepted: 0, rejected: 0, replayed: 0, dropped: 0 },
  byKind: {},           // per action: { accepted, rejected }
  rejections: [],       // last 15: { at, action, message }
  recentTransfers: [],  // transfers we may later refund
  usedKeys: [],         // keys we may later "retry" (double-click simulation)
};
let timer = null;
let stopTimer = null;

const pick = (list) => list[Math.floor(Math.random() * list.length)];
const rupees = (min, max) => (min + Math.floor(Math.random() * (max - min + 1))) * 100;

async function ensureWallets() {
  const existing = await callFunction('app', 'SELECT * FROM ledger.list_wallets($1, $2)', [SIM_TAG, 200]);
  const wallets = existing.map((row) => row.account_id);
  for (let i = wallets.length; i < USER_COUNT; i += 1) {
    const name = NAMES[i % NAMES.length];
    const email = `${name.toLowerCase()}.${randomUUID().slice(0, 6)}@${SIM_TAG}.example`;
    await callFunction('app', 'SELECT ledger.create_user_with_wallet($1, $2)', [name, email]);
  }
  const all = await callFunction('app', 'SELECT * FROM ledger.list_wallets($1, $2)', [SIM_TAG, 200]);
  // New wallets start with some (simulated) money from the bank.
  for (const row of all) {
    if (Number(row.balance) < 50000) {
      await callFunction('app', 'SELECT ledger.top_up($1, $2, $3)', [row.account_id, rupees(2000, 8000), randomUUID()]);
    }
  }
  return all.map((row) => row.account_id);
}

// One simulated user action. Mostly normal payments, plus a share of requests the
// database must refuse (overspend, self-transfer, over-refund, reused key).
function chooseAction() {
  const roll = Math.random();
  const from = pick(state.wallets);
  let to = pick(state.wallets);
  if (to === from) to = state.wallets[(state.wallets.indexOf(from) + 1) % state.wallets.length];

  if (roll < 0.55) {
    return { action: 'transfer', sql: 'SELECT ledger.transfer($1, $2, $3, $4) AS id', params: [from, to, rupees(50, 2500), randomUUID()], remember: true };
  }
  if (roll < 0.65) return { action: 'top-up', sql: 'SELECT ledger.top_up($1, $2, $3) AS id', params: [from, rupees(500, 5000), randomUUID()] };
  if (roll < 0.72) return { action: 'withdrawal', sql: 'SELECT ledger.withdraw($1, $2, $3) AS id', params: [from, rupees(100, 1500), randomUUID()] };
  if (roll < 0.78 && state.recentTransfers.length) {
    const original = pick(state.recentTransfers);
    return { action: 'refund', sql: 'SELECT ledger.refund($1, $2, $3) AS id', params: [original, rupees(10, 300), randomUUID()] };
  }
  if (roll < 0.84 && state.usedKeys.length) {
    // The same request again with the same key: a retry after a dropped network.
    const earlier = pick(state.usedKeys);
    return { ...earlier, action: 'retry (same key)', replay: true };
  }
  if (roll < 0.90) {
    return { action: 'overspend', sql: 'SELECT ledger.transfer($1, $2, $3, $4) AS id', params: [from, to, rupees(200000, 500000), randomUUID()] };
  }
  if (roll < 0.94) {
    return { action: 'self-transfer', sql: 'SELECT ledger.transfer($1, $2, $3, $4) AS id', params: [from, from, rupees(10, 100), randomUUID()] };
  }
  if (state.recentTransfers.length) {
    return { action: 'over-refund', sql: 'SELECT ledger.refund($1, $2, $3) AS id', params: [pick(state.recentTransfers), rupees(100000, 200000), randomUUID()] };
  }
  return { action: 'transfer', sql: 'SELECT ledger.transfer($1, $2, $3, $4) AS id', params: [from, to, rupees(50, 2500), randomUUID()], remember: true };
}

function tally(action, outcome) {
  state.byKind[action] ??= { accepted: 0, rejected: 0 };
  state.byKind[action][outcome] += 1;
}

async function fireOne() {
  if (state.inFlight >= MAX_IN_FLIGHT) { state.counts.dropped += 1; return; }
  const request = chooseAction();
  state.inFlight += 1;
  state.counts.attempted += 1;
  try {
    const [row] = await callFunction('app', request.sql, request.params);
    if (request.replay) {
      state.counts.replayed += 1;   // same id returned, no new money moved
    } else {
      state.counts.accepted += 1;
      if (request.remember) {
        state.recentTransfers = [row.id, ...state.recentTransfers].slice(0, 40);
        state.usedKeys = [request, ...state.usedKeys].slice(0, 40);
      }
    }
    tally(request.action, 'accepted');
  } catch (error) {
    state.counts.rejected += 1;
    tally(request.action, 'rejected');
    state.rejections = [
      { at: new Date().toISOString(), action: request.action, code: error.code ?? null, message: error.message },
      ...state.rejections,
    ].slice(0, 15);
  } finally {
    state.inFlight -= 1;
  }
}

export async function start(rate) {
  const perSecond = Math.min(Math.max(Number(rate) || 5, 1), 20);
  if (state.running || state.starting) return status();
  state.starting = true;
  try {
    state.wallets = await ensureWallets();
  } finally {
    state.starting = false;
  }
  Object.assign(state, {
    running: true,
    rate: perSecond,
    startedAt: new Date().toISOString(),
    counts: { attempted: 0, accepted: 0, rejected: 0, replayed: 0, dropped: 0 },
    byKind: {},
    rejections: [],
  });
  timer = setInterval(() => { fireOne(); }, 1000 / perSecond);
  stopTimer = setTimeout(stop, MAX_RUN_MS);
  return status();
}

export function stop() {
  clearInterval(timer);
  clearTimeout(stopTimer);
  timer = null;
  state.running = false;
  return status();
}

export function status() {
  const { running, starting, rate, startedAt, inFlight, counts, byKind, rejections } = state;
  return { running, starting, rate, startedAt, users: state.wallets.length, inFlight, counts, byKind, rejections };
}
