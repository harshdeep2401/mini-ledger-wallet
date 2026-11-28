import { useEffect, useState } from 'react';
import { adminApi, formatRupees } from '../api.js';

// Every ledger leg of one transaction, and the refunds made against it.
export default function Tracer({ transactionId, onSelect }) {
  const [legs, setLegs] = useState([]);
  const [refunds, setRefunds] = useState([]);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!transactionId) return;
    let alive = true;
    setError('');
    Promise.all([adminApi.legs(transactionId), adminApi.refunds(transactionId)])
      .then(([l, r]) => { if (alive) { setLegs(l); setRefunds(r); } })
      .catch((e) => alive && setError(e.message));
    return () => { alive = false; };
  }, [transactionId]);

  if (!transactionId) {
    return <section className="card muted">Click a transaction in the feed to trace it.</section>;
  }
  if (error) return <section className="card error">{error}</section>;
  if (legs.length === 0) return <section className="card muted">Loading…</section>;

  const head = legs[0];
  const debits = legs.filter((l) => l.direction === 'debit').reduce((s, l) => s + Number(l.amount), 0);
  const credits = legs.filter((l) => l.direction === 'credit').reduce((s, l) => s + Number(l.amount), 0);

  return (
    <section className="card">
      <h3 style={{ marginTop: 0 }}>Transaction #{head.transaction_id} <span className={`type ${head.type}`}>{head.type}</span></h3>
      <p className="muted">
        {new Date(head.created_at).toLocaleString()}
        {head.reverses_transaction_id && <> · refunds <a href="#" onClick={(e) => { e.preventDefault(); onSelect(head.reverses_transaction_id); }}>#{head.reverses_transaction_id}</a></>}
      </p>
      <table className="compact">
        <thead><tr><th>Account</th><th className="right">Debit</th><th className="right">Credit</th></tr></thead>
        <tbody>
          {legs.map((l) => (
            <tr key={l.entry_id}>
              <td>{l.account_label} <span className="muted">#{l.account_id}</span></td>
              <td className="right">{l.direction === 'debit' ? formatRupees(l.amount) : ''}</td>
              <td className="right">{l.direction === 'credit' ? formatRupees(l.amount) : ''}</td>
            </tr>
          ))}
          <tr className="total"><td>Total</td><td className="right">{formatRupees(debits)}</td><td className="right">{formatRupees(credits)}</td></tr>
        </tbody>
      </table>
      <p className={debits === credits ? 'ok' : 'error'}>{debits === credits ? 'Debits = credits' : 'Debits ≠ credits'}</p>

      {head.type === 'transfer' && (
        <>
          <h4 className="subhead">Refunds against this transfer</h4>
          {refunds.length === 0
            ? <p className="muted">None yet.</p>
            : (
              <table className="compact">
                <thead><tr><th>Refund</th><th className="right">Amount</th><th className="right">Left to refund</th></tr></thead>
                <tbody>
                  {refunds.map((r) => (
                    <tr key={r.refund_transaction_id} onClick={() => onSelect(r.refund_transaction_id)}>
                      <td>#{r.refund_transaction_id}</td>
                      <td className="right">{formatRupees(r.amount)}</td>
                      <td className="right">{formatRupees(r.remaining_after)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
        </>
      )}
    </section>
  );
}
