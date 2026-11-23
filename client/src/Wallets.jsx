import { useEffect, useState } from 'react';
import { api, formatRupees } from './api.js';

export default function Wallets({ selected, onSelect }) {
  const [search, setSearch] = useState('');
  const [wallets, setWallets] = useState([]);
  const [error, setError] = useState('');
  const [form, setForm] = useState({ name: '', email: '' });
  const [message, setMessage] = useState('');

  useEffect(() => {
    api.wallets(search).then(setWallets).catch((e) => setError(e.message));
  }, [search]);

  async function create(event) {
    event.preventDefault();
    setMessage('');
    try {
      await api.createWallet(form.name, form.email);
      setMessage(`Created a wallet for ${form.name}.`);
      setForm({ name: '', email: '' });
      setSearch(form.email); // show the new wallet
      setWallets(await api.wallets(form.email));
    } catch (e) {
      setMessage(e.message);
    }
  }

  return (
    <section className="card">
      <h2>Wallets</h2>
      <input placeholder="Search by name or email" value={search} onChange={(e) => setSearch(e.target.value)} />
      {error && <p className="error">{error}</p>}
      <ul className="list">
        {wallets.map((w) => (
          <li key={w.account_id}
              className={selected?.account_id === w.account_id ? 'selected' : ''}
              onClick={() => onSelect(w)}>
            <div>
              <strong>{w.name}</strong>
              <div className="muted">{w.email}</div>
            </div>
            <div className="right">
              <div>{formatRupees(w.balance)}</div>
              {w.status !== 'active' && <span className="tag">{w.status}</span>}
            </div>
          </li>
        ))}
        {wallets.length === 0 && <li className="muted">No wallets found.</li>}
      </ul>

      <h3>New wallet</h3>
      <form onSubmit={create}>
        <input required placeholder="Name" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
        <input required type="email" placeholder="Email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
        <button>Create wallet</button>
      </form>
      {message && <p className="muted">{message}</p>}
    </section>
  );
}
