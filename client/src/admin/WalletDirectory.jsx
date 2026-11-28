import { useEffect, useState } from 'react';
import { adminApi as api, formatRupees } from '../api.js';

// Every wallet with its balance, for the operator (ledger_admin), plus freeze/unfreeze.
export default function WalletDirectory() {
  const [search, setSearch] = useState('');
  const [wallets, setWallets] = useState([]);
  const [message, setMessage] = useState('');

  const load = () => api.wallets(search, 20).then(setWallets).catch((e) => setMessage(e.message));
  useEffect(() => {
    const t = setTimeout(load, 200);
    return () => clearTimeout(t);
  }, [search]); // eslint-disable-line react-hooks/exhaustive-deps

  async function setFrozen(wallet, freeze) {
    try {
      await (freeze ? api.freeze(wallet.account_id) : api.unfreeze(wallet.account_id));
      setMessage(`${wallet.name} #${wallet.account_id} ${freeze ? 'frozen' : 'unfrozen'}.`);
      load();
    } catch (e) { setMessage(e.message); }
  }

  return (
    <section className="card">
      <h3 style={{ marginTop: 0 }}>Wallets</h3>
      <input placeholder="Search by name or email" value={search} onChange={(e) => setSearch(e.target.value)} />
      {message && <p className="muted">{message}</p>}
      <div className="feed" style={{ maxHeight: 320 }}>
        <table className="compact">
          <thead><tr><th>#</th><th>Name</th><th>Email</th><th className="right">Balance</th><th /></tr></thead>
          <tbody>
            {wallets.map((w) => (
              <tr key={w.account_id}>
                <td>{w.account_id}</td>
                <td>{w.name} {w.status !== 'active' && <span className="tag">{w.status}</span>}</td>
                <td className="muted">{w.email}</td>
                <td className="right">{formatRupees(w.balance)}</td>
                <td className="right">
                  {w.status === 'active'
                    ? <button className="small danger" onClick={() => setFrozen(w, true)}>Freeze</button>
                    : <button className="small" onClick={() => setFrozen(w, false)}>Unfreeze</button>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
