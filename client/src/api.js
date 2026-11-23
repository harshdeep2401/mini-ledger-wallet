// Thin client for the Express API. Money amounts are integers in paise.

async function request(method, url, { body, key } = {}) {
  const response = await fetch(url, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(key ? { 'Idempotency-Key': key } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw Object.assign(new Error(data.error ?? 'Request failed'), { status: response.status });
  return data;
}

export const api = {
  wallets: (search = '', limit = 50) => request('GET', `/api/wallets?search=${encodeURIComponent(search)}&limit=${limit}`),
  createWallet: (name, email) => request('POST', '/api/wallets', { body: { name, email } }),
  balance: (id) => request('GET', `/api/wallets/${id}/balance`),
  history: (id, cursor) => {
    const params = new URLSearchParams({ limit: '10', ...(cursor ?? {}) });
    return request('GET', `/api/wallets/${id}/history?${params}`);
  },
  topUp: (body, key) => request('POST', '/api/top-ups', { body, key }),
  withdraw: (body, key) => request('POST', '/api/withdrawals', { body, key }),
  transfer: (body, key) => request('POST', '/api/transfers', { body, key }),
  refund: (body, key) => request('POST', '/api/refunds', { body, key }),
  fee: (amount) => request('GET', `/api/fee?amount=${amount}`),
  freeze: (id) => request('POST', `/api/accounts/${id}/freeze`),
  unfreeze: (id) => request('POST', `/api/accounts/${id}/unfreeze`),
  reconciliation: () => request('GET', '/api/reconciliation'),
  issues: () => request('GET', '/api/reconciliation/issues'),
};

// The presenter's console (/api/demo/*).
export const demoApi = {
  scenarios: () => request('GET', '/api/demo/scenarios'),
  start: (scenario) => request('POST', '/api/demo/runs', { body: { scenario } }),
  next: (runId) => request('POST', `/api/demo/runs/${runId}/next`, { body: {} }),
  health: () => request('GET', '/api/demo/health'),
  performance: () => request('GET', '/api/demo/performance'),
  // Tell the server we are leaving; it repairs anything the tamper demo corrupted.
  abort: (runId, { keepalive = false } = {}) =>
    fetch(`/api/demo/runs/${runId}`, { method: 'DELETE', keepalive }).catch(() => {}),
};

// Reads a text stream (the concurrency demos) and calls onText for every chunk.
export async function streamText(url, onText) {
  const response = await fetch(url);
  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    throw new Error(data.error ?? 'Request failed');
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    onText(decoder.decode(value, { stream: true }));
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
