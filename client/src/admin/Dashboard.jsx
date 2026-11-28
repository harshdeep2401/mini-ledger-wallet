import { useEffect, useState } from 'react';
import { adminApi, formatRupees } from '../api.js';

// Totals from ledger.ledger_stats() every 3 s, and a full reconciliation every 10 s.
export default function Dashboard() {
  const [stats, setStats] = useState(null);
  const [books, setBooks] = useState(null); // { healthy, ms, at }
  const [error, setError] = useState('');

  useEffect(() => {
    let alive = true;
    const loadStats = () => adminApi.stats()
      .then((s) => { if (alive) { setStats(s); setError(''); } })
      .catch((e) => alive && setError(e.message));
    const reconcile = async () => {
      const started = performance.now();
      try {
        const { healthy } = await adminApi.reconciliation();
        if (alive) setBooks({ healthy, ms: Math.round(performance.now() - started), at: new Date() });
      } catch (e) { if (alive) setError(e.message); }
    };
    loadStats(); reconcile();
    const a = setInterval(loadStats, 3000);
    const b = setInterval(reconcile, 10000);
    return () => { alive = false; clearInterval(a); clearInterval(b); };
  }, []);

  if (error && !stats) return <section className="card error">{error}</section>;
  if (!stats) return <section className="card muted">Loading totals…</section>;

  const balanced = Number(stats.books_difference) === 0;
  return (
    <section className="card">
      <div className="tiles">
        <Tile label="Transactions" value={Number(stats.transaction_count).toLocaleString('en-IN')} />
        <Tile label="Last minute" value={stats.last_minute} />
        <Tile label="Wallets" value={Number(stats.wallet_count).toLocaleString('en-IN')} />
        <Tile label="Fee income" value={formatRupees(stats.fee_income)} />
        <div className={`tile ${books?.healthy === false ? 'bad' : 'good'}`}>
          <div className="tile-label">Reconciliation</div>
          <div className="tile-value">{books ? (books.healthy ? '0 issues' : 'ISSUES') : '…'}</div>
          {books && <div className="tile-note">{books.ms} ms · {books.at.toLocaleTimeString()}</div>}
        </div>
      </div>

      <div className={`equation ${balanced ? 'good' : 'bad'}`}>
        <span><small>BANK</small>{formatRupees(stats.bank_balance)}</span>
        <b>=</b>
        <span><small>All wallets</small>{formatRupees(stats.wallet_total)}</span>
        <b>+</b>
        <span><small>Fee income</small>{formatRupees(stats.fee_income)}</span>
        <span className="diff"><small>Difference</small>{formatRupees(stats.books_difference)}</span>
      </div>
    </section>
  );
}

function Tile({ label, value }) {
  return (
    <div className="tile">
      <div className="tile-label">{label}</div>
      <div className="tile-value">{value}</div>
    </div>
  );
}
