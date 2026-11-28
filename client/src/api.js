// Thin client for the Express API. Money amounts are integers in paise.

// The current session: { role: 'user' | 'admin', token }. Kept for this browser tab only
// (sessionStorage) and sent as "Authorization: Bearer <token>". The database checks the
// token on every call; the browser only remembers it.
const SESSION_KEY = 'mini-ledger-session';
let current = null;
try { current = JSON.parse(sessionStorage.getItem(SESSION_KEY)); } catch { /* storage blocked */ }

export const session = {
  get: () => current,
  set(value) {
    current = value;
    try {
      if (value) sessionStorage.setItem(SESSION_KEY, JSON.stringify(value));
      else sessionStorage.removeItem(SESSION_KEY);
    } catch { /* ignore */ }
  },
};

const authHeader = () => (current?.token ? { Authorization: `Bearer ${current.token}` } : {});

async function request(method, url, { body, key } = {}) {
  const response = await fetch(url, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(key ? { 'Idempotency-Key': key } : {}),
      ...authHeader(),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = response.status === 204 ? {} : await response.json().catch(() => ({}));
  // 401 while logged in: the session expired or was logged out. Back to the log-in page.
  if (response.status === 401 && current) {
    session.set(null);
    window.dispatchEvent(new Event('session-ended'));
  }
  if (!response.ok) throw Object.assign(new Error(data.error ?? 'Request failed'), { status: response.status });
  return data;
}

// Wallet users (ledger_web, token functions). No request names a source wallet.
export const api = {
  signUp: (body) => request('POST', '/api/auth/sign-up', { body }),
  logIn: (body) => request('POST', '/api/auth/log-in', { body }),
  logOut: () => request('POST', '/api/auth/log-out', { body: {} }),
  me: () => request('GET', '/api/me'),
  history: (cursor) => {
    const params = new URLSearchParams({ limit: '10', ...(cursor ?? {}) });
    return request('GET', `/api/me/history?${params}`);
  },
  recipients: (search = '') => request('GET', `/api/me/recipients?search=${encodeURIComponent(search)}&limit=10`),
  topUp: (body, key) => request('POST', '/api/me/top-ups', { body, key }),
  withdraw: (body, key) => request('POST', '/api/me/withdrawals', { body, key }),
  transfer: (body, key) => request('POST', '/api/me/transfers', { body, key }),
  refund: (body, key) => request('POST', '/api/me/refunds', { body, key }),
  fee: (amount) => request('GET', `/api/fee?amount=${amount}`),
};

// Admins (token-checked admin_* functions).
export const adminApi = {
  signUp: (body) => request('POST', '/api/admin/auth/sign-up', { body }),
  logIn: (body) => request('POST', '/api/admin/auth/log-in', { body }),
  logOut: () => request('POST', '/api/admin/auth/log-out', { body: {} }),
  me: () => request('GET', '/api/admin/me'),
  stats: () => request('GET', '/api/admin/stats'),
  feed: (limit = 30) => request('GET', `/api/admin/feed?limit=${limit}`),
  legs: (id) => request('GET', `/api/admin/transactions/${id}`),
  refunds: (id) => request('GET', `/api/admin/transactions/${id}/refunds`),
  wallets: (search = '', limit = 50) => request('GET', `/api/admin/wallets?search=${encodeURIComponent(search)}&limit=${limit}`),
  freeze: (id) => request('POST', `/api/admin/wallets/${id}/freeze`),
  unfreeze: (id) => request('POST', `/api/admin/wallets/${id}/unfreeze`),
  reconciliation: () => request('GET', '/api/admin/reconciliation'),
  issues: () => request('GET', '/api/admin/reconciliation/issues'),
  simulator: () => request('GET', '/api/admin/simulator'),
  startSimulator: (rate) => request('POST', '/api/admin/simulator/start', { body: { rate } }),
  stopSimulator: () => request('POST', '/api/admin/simulator/stop', { body: {} }),
};

// The presenter's console (/api/demo/*), admin only.
export const demoApi = {
  scenarios: () => request('GET', '/api/demo/scenarios'),
  start: (scenario) => request('POST', '/api/demo/runs', { body: { scenario } }),
  next: (runId) => request('POST', `/api/demo/runs/${runId}/next`, { body: {} }),
  health: () => request('GET', '/api/demo/health'),
  performance: () => request('GET', '/api/demo/performance'),
  // Tell the server we are leaving; it repairs anything the tamper demo corrupted.
  abort: (runId, { keepalive = false } = {}) =>
    fetch(`/api/demo/runs/${runId}`, { method: 'DELETE', keepalive, headers: authHeader() }).catch(() => {}),
};

async function openStream(url, signal) {
  const response = await fetch(url, { headers: authHeader(), signal });
  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    throw new Error(data.error ?? 'Request failed');
  }
  return response.body.getReader();
}

// Reads a text stream (the concurrency demos) and calls onText for every chunk.
export async function streamText(url, onText) {
  const reader = await openStream(url);
  const decoder = new TextDecoder();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    onText(decoder.decode(value, { stream: true }));
  }
}

// Reads Server-Sent Events with the Authorization header (EventSource cannot send one).
// Calls onEvent(name, data) for each event until the signal aborts or the stream ends.
export async function streamEvents(url, onEvent, signal) {
  const reader = await openStream(url, signal);
  const decoder = new TextDecoder();
  let buffer = '';
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return;
    buffer += decoder.decode(value, { stream: true });
    let end;
    while ((end = buffer.indexOf('\n\n')) >= 0) {
      const block = buffer.slice(0, end);
      buffer = buffer.slice(end + 2);
      let name = 'message';
      let data = '';
      for (const line of block.split('\n')) {
        if (line.startsWith('event: ')) name = line.slice(7);
        else if (line.startsWith('data: ')) data += line.slice(6);
      }
      if (data) onEvent(name, JSON.parse(data));
    }
  }
}

// "12.50" -> 1250 paise. Returns null if the text is not a rupee amount.
export function rupeesToPaise(text) {
  if (!/^\d+(\.\d{1,2})?$/.test(text.trim())) return null;
  return Math.round(Number(text) * 100);
}

export const formatRupees = (paise) => {
  const value = Number(paise) / 100;
  const text = Math.abs(value).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return `${value < 0 ? '−' : ''}₹${text}`;
};
