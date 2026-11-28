import { useEffect, useState } from 'react';
import { api, formatRupees, rupeesToPaise } from '../api.js';
import { useAction } from '../useAction.js';
import Pay from './Pay.jsx';

// Add money or withdraw: one idempotency key per action (see useAction).
function MoneyForm({ label, verb, send, onDone }) {
  const [amount, setAmount] = useState('');
  const action = useAction(send);

  async function submit(event) {
    event.preventDefault();
    const paise = rupeesToPaise(amount);
    const result = await action.run({ amount: paise ?? (amount || null) });
    if (result) { setAmount(''); onDone(); }
  }

  return (
    <section className="card">
      <h3 style={{ marginTop: 0 }}>{label}</h3>
      <form onSubmit={submit}>
        <label>Amount (₹)<input autoFocus placeholder="1000" value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
        <button className="primary">{verb}</button>
      </form>
      {action.state.status === 'error' && <p className="error">{action.state.error}</p>}
      {action.state.status === 'done' && <p className="ok">Done. Reference #{action.state.result.transaction_id}</p>}
    </section>
  );
}

// Only a transfer you RECEIVED shows a refund button; the database enforces the same rule.
function RefundButton({ entry, onDone }) {
  const action = useAction(api.refund);
  const refund = () => action.run({ original_transaction_id: entry.transaction_id, amount: entry.amount })
    .then((result) => result && onDone());
  return (
    <>
      <button className="small" onClick={refund}>Refund</button>
      {action.state.status === 'error' && <div className="error">{action.state.error}</div>}
    </>
  );
}

const LABELS = { topup: 'Added money', withdrawal: 'Withdrawal', transfer: 'Transfer', refund: 'Refund' };

export default function UserDashboard({ onLogOut }) {
  const [me, setMe] = useState(null);
  const [entries, setEntries] = useState([]);
  const [next, setNext] = useState(null);
  const [panel, setPanel] = useState('transfer');
  const [error, setError] = useState('');

  async function load() {
    try {
      setError('');
      const [wallet, h] = await Promise.all([api.me(), api.history()]);
      setMe(wallet);
      setEntries(h.entries);
      setNext(h.next_cursor);
    } catch (e) { setError(e.message); }
  }
  useEffect(() => { load(); }, []);

  async function loadMore() {
    const h = await api.history(next);
    setEntries((current) => [...current, ...h.entries]);
    setNext(h.next_cursor);
  }

  if (!me) return <section className="card muted">{error || 'Loading your wallet…'}</section>;

  return (
    <div className="dashboard">
      <div className="topbar">
        <div>
          <div className="hello">Hi, {me.name}</div>
          <div className="muted">{me.email} · wallet #{me.account_id}</div>
        </div>
        <button className="small" onClick={onLogOut}>Log out</button>
      </div>

      <section className="card balance-card">
        <div className="muted">Available balance</div>
        <div className="balance">{formatRupees(me.balance)}</div>
        {me.status !== 'active' && <p className="warn">This wallet is {me.status}. Payments will be refused.</p>}
        <div className="segmented">
          <button className={panel === 'topup' ? 'on' : ''} onClick={() => setPanel('topup')}>＋ Add money</button>
          <button className={panel === 'withdraw' ? 'on' : ''} onClick={() => setPanel('withdraw')}>↓ Withdraw</button>
          <button className={panel === 'transfer' ? 'on' : ''} onClick={() => setPanel('transfer')}>→ Transfer</button>
        </div>
      </section>

      <div className="columns">
        <div>
          {panel === 'topup' && <MoneyForm key="topup" label="Add money from the bank" verb="Add money" send={api.topUp} onDone={load} />}
          {panel === 'withdraw' && <MoneyForm key="withdraw" label="Withdraw to the bank" verb="Withdraw" send={api.withdraw} onDone={load} />}
          {panel === 'transfer' && <Pay onChanged={load} />}
        </div>

        <section className="card">
          <div className="between">
            <h3 style={{ marginTop: 0 }}>Recent activity</h3>
            <button className="small" onClick={load}>Refresh</button>
          </div>
          <ul className="activity">
            {entries.map((e) => (
              <li key={e.entry_id}>
                <div>
                  <b>{LABELS[e.type] ?? e.type}</b> {e.other_party && <span className="muted">· {e.other_party}</span>}
                  <div className="muted">{new Date(e.created_at).toLocaleString()} · ref #{e.transaction_id}</div>
                </div>
                <div className="right">
                  <div className={Number(e.signed_change) < 0 ? 'neg' : 'pos'}>
                    {Number(e.signed_change) < 0 ? '−' : '+'}{formatRupees(Math.abs(Number(e.signed_change)))}
                  </div>
                  {e.type === 'transfer' && e.direction === 'credit' && <RefundButton entry={e} onDone={load} />}
                </div>
              </li>
            ))}
            {entries.length === 0 && <li className="muted">No activity yet. Add money to get started.</li>}
          </ul>
          {next && <button className="small" onClick={loadMore}>Load more</button>}
        </section>
      </div>
    </div>
  );
}
