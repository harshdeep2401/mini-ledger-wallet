// Live feed for the admin page.
// PostgreSQL announces every committed transaction on channel 'ledger_events'
// (trigger in db/11_admin_monitor.sql). This file keeps ONE listening connection,
// fetches the new rows with ledger.recent_transactions(), and pushes them to every
// open admin page as Server-Sent Events. Rolled-back payments are never announced.
import pg from 'pg';
import { callFunction } from './db.js';

const browsers = new Set();   // open SSE responses
let listener = null;
let fetchTimer = null;
// Ids announced but not yet sent. Commits can finish out of order (id 11 before 10),
// so we fetch exactly the announced ids, never "everything after the last id".
const pending = new Set();

function send(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function broadcast(event, data) {
  for (const res of browsers) send(res, event, data);
}

// Neon's "-pooler" address runs PgBouncer, which cannot hold a LISTEN.
// The listener uses the direct address of the same database instead.
function directUrl() {
  const url = process.env.ADMIN_DATABASE_URL;
  return url ? url.replace('-pooler.', '.') : null;
}

async function fetchNew() {
  fetchTimer = null;
  if (pending.size === 0) return;
  const ids = [...pending];
  pending.clear();
  try {
    const oldest = Math.min(...ids);
    const rows = await callFunction('admin',
      'SELECT * FROM ledger.recent_transactions($1, $2)', [200, oldest - 1]);
    const wanted = new Set(ids.map(String));
    const announced = rows.filter((row) => wanted.has(String(row.transaction_id)));
    if (announced.length) broadcast('transactions', announced);
  } catch (error) {
    console.error('live feed fetch failed:', error.message);
  }
}

// Every caller waits for the same connection, so nobody is told "ready" before LISTEN runs.
let starting = null;
function startListening() {
  if (!starting) starting = connectListener().catch((error) => { starting = null; throw error; });
  return starting;
}

async function connectListener() {
  const connectionString = directUrl();
  if (!connectionString) throw new Error('admin database login is not configured');
  listener = new pg.Client({ connectionString });
  listener.on('notification', (message) => {
    const payload = JSON.parse(message.payload);
    broadcast('notify', { channel: message.channel, payload });
    pending.add(payload.id);
    // Many commits can arrive together; fetch them in one call.
    if (!fetchTimer) fetchTimer = setTimeout(fetchNew, 150);
  });
  listener.on('error', (error) => {
    console.error('live feed listener lost:', error.message);
    listener = null;
    starting = null;
    setTimeout(() => { if (browsers.size) startListening().catch(() => {}); }, 3000);
  });
  await listener.connect();
  await listener.query('LISTEN ledger_events');
}

async function stopListening() {
  const client = listener;
  listener = null;
  starting = null;
  await client?.end().catch(() => {});
}

// GET /api/admin/events
export async function eventsRoute(req, res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });
  browsers.add(res);
  const keepAlive = setInterval(() => res.write(': keep-alive\n\n'), 20000);
  req.on('close', () => {
    clearInterval(keepAlive);
    browsers.delete(res);
    if (browsers.size === 0) stopListening();
  });

  try {
    await startListening();
    send(res, 'ready', { listening: 'ledger_events' });
  } catch (error) {
    send(res, 'failed', { error: error.message });
  }
}
