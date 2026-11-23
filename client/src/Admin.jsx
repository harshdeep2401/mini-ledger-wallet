import { useState } from 'react';
import { api } from './api.js';

export default function Admin() {
  const [result, setResult] = useState(null);
  const [issues, setIssues] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function check() {
    setBusy(true); setError(''); setIssues([]);
    const started = performance.now();
    try {
      const { healthy } = await api.reconciliation();
      const found = healthy ? [] : await api.issues();
      setIssues(found);
      setResult({ healthy, ms: Math.round(performance.now() - started) });
    } catch (e) { setError(e.message); }
    setBusy(false);
  }

  return (
    <section className="card narrow">
      <h2>Ledger check</h2>
      <p className="muted">
        Re-adds every ledger entry from scratch and compares it with the stored balances.
        On a large ledger this takes about a second.
      </p>
      <button onClick={check} disabled={busy}>{busy ? 'Checking…' : 'Check ledger'}</button>
      {error && <p className="error">{error}</p>}
      {result && (
        <p className={result.healthy ? 'ok big' : 'error big'}>
          {result.healthy ? 'Ledger is healthy' : `${issues.length} problem(s) found`} ({result.ms} ms)
        </p>
      )}
      {issues.length > 0 && (
        <table>
          <thead><tr><th>Check</th><th>Account</th><th>Transaction</th><th>Expected</th><th>Actual</th></tr></thead>
          <tbody>
            {issues.map((issue, i) => (
              <tr key={i}>
                <td>{issue.check_name}</td><td>{issue.account_id}</td><td>{issue.transaction_id}</td>
                <td>{issue.expected}</td><td>{issue.actual}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
