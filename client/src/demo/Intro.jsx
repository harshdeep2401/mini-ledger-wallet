const GUARANTEES = [
  ['Every transaction balances (debits = credits)', 'Deferred trigger, checked at commit'],
  ['History cannot be rewritten', 'Trigger blocks UPDATE/DELETE; app login has no table access'],
  ['No negative amounts', 'CHECK (amount > 0)'],
  ['No overdraft', 'Check inside the posting function, on a locked row'],
  ['Frozen accounts cannot move money', 'Trigger on ledger entries'],
  ['A retry does not charge twice', 'Idempotency key table'],
  ['A refund cannot exceed the original', 'Check inside refund()'],
  ['Cached balances are honest', 'Reconciliation re-adds every entry'],
];

export default function Intro() {
  return (
    <section className="card">
      <h2>Mini Ledger Wallet</h2>
      <p className="pitch">
        The <b>database itself</b> guarantees money cannot be created, lost, double-spent or silently edited, even if the app is buggy.
      </p>
      <div className="arch">
        <div className="box">Browser</div>
        <div className="arrow">→</div>
        <div className="box">Express server</div>
        <div className="arrow">→</div>
        <div className="box strong">PostgreSQL</div>
      </div>
            <table>
        
        <tbody>{GUARANTEES.map(([a, b]) => <tr key={a}><td>{a}</td><td className="muted">{b}</td></tr>)}</tbody>
      </table>
    </section>
  );
}
