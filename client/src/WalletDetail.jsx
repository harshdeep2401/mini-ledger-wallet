import { useEffect, useState } from 'react';
import { api, formatRupees, rupeesToPaise } from './api.js';
import { useAction } from './useAction.js';

// Top-up or withdraw form: one idempotency key per action (see useAction).
function MoneyForm({ label, wallet, send, onDone }) {
  const [amount, setAmount] = useState('');
  const action = useAction(send);

  async function submit(event) {
    event.preventDefault();
    const paise = rupeesToPaise(amount);
    if (paise === null) return action.run({ wallet_account_id: wallet.account_id, amount: amount || null });
    const result = await action.run({ wallet_account_id: wallet.account_id, amount: paise });
    if (result) { setAmount(''); onDone(); }
  }

  return (
    <form onSubmit={submit} className="inline">
      <input placeholder="Amount in ₹" value={amount} onChange={(e) => setAmount(e.target.value)} />
      <button>{label}</button>
      {action.state.status === 'error' && <span className="error">{action.state.error}</span>}
      {action.state.status === 'done' && <span className="ok">Done. Ref #{action.state.result.transaction_id}</span>}
    </form>
  );
}

function RefundButton({ entry, onDone }) {
  const action = useAction((body, key) => api.refund(body, key));
  const refund = () => action.run({ original_transaction_id: entry.transaction_id, amount: entry.amount })
    .then((result) => result && onDone());
  return (
    <>
      <button className="small" onClick={refund}>Refund</button>
      {action.state.status === 'error' && <div className="error">{action.state.error}</div>}
    </>
  );
}

export default function WalletDetail({ wallet, onChanged }) {
  const [balance, setBalance] = useState(null);
  const [entries, setEntries] = useState([]);
  const [next, setNext] = useState(null);
  const [error, setError] = useState('');
  const [adminMessage, setAdminMessage] = useState('');

  async function load() {
    try {
      setError('');
      const [b, h] = await Promise.all([api.balance(wallet.account_id), api.history(wallet.account_id)]);
      setBalance(b.balance);
      setEntries(h.entries);
      setNext(h.next_cursor);
    } catch (e) { setError(e.message); }
  }
  useEffect(() => { load(); }, [wallet.account_id]); // eslint-disable-line react-hooks/exhaustive-deps

  async function loadMore() {
    const h = await api.history(wallet.account_id, next);
    setEntries((current) => [...current, ...h.entries]);
    setNext(h.next_cursor);
  }

  async function setFrozen(freeze) {
    try {
      await (freeze ? api.freeze(wallet.account_id) : api.unfreeze(wallet.account_id));
      setAdminMessage(freeze ? 'Account frozen.' : 'Account unfrozen.');
      onChanged();
    } catch (e) { setAdminMessage(e.message); }
  }

  const done = () => { load(); onChanged(); };

  return (
    <section className="card">
      <h2>{wallet.name}</h2>
      <div className="muted">{wallet.email} · account {wallet.account_id}</div>
      <div className="balance">{balance === null ? '…' : formatRupees(balance)}</div>
      {error && <p className="error">{error}</p>}

      <div className="actions">
        <MoneyForm label="Add money" wallet={wallet} send={api.topUp} onDone={done} />
        <MoneyForm label="Withdraw" wallet={wallet} send={api.withdraw} onDone={done} />
      </div>

      <div className="actions">
        {wallet.status === 'active'
          ? <button className="small danger" onClick={() => setFrozen(true)}>Freeze account (admin)</button>
          : <button className="small" onClick={() => setFrozen(false)}>Unfreeze account (admin)</button>}
        {adminMessage && <span className="muted">{adminMessage}</span>}
      </div>

      <h3>History</h3>
      <table>
        <thead><tr><th>When</th><th>What</th><th>With</th><th className="right">Amount</th><th /></tr></thead>
        <tbody>
          {entries.map((e) => (
            <tr key={e.entry_id}>
              <td>{new Date(e.created_at).toLocaleString()}</td>
              <td>{e.type}<div className="muted">ref #{e.transaction_id}</div></td>
              <td>{e.other_party}</td>
              <td className={`right ${Number(e.signed_change) < 0 ? 'neg' : 'pos'}`}>
                {Number(e.signed_change) < 0 ? '−' : '+'}{formatRupees(Math.abs(Number(e.signed_change)))}
              </td>
              <td>{e.type === 'transfer' && e.direction === 'credit' && <RefundButton entry={e} onDone={done} />}</td>
            </tr>
          ))}
          {entries.length === 0 && <tr><td colSpan="5" className="muted">No activity yet.</td></tr>}
        </tbody>
      </table>
      {next && <button onClick={loadMore}>Load more</button>}
    </section>
  );
}
