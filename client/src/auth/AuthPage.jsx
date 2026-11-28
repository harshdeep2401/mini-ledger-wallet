import { useState } from 'react';
import { api, adminApi, session } from '../api.js';

// Landing page: log in or sign up, as a wallet user or as an admin.
// The database checks every password (bcrypt) and hands back a session token.
export default function AuthPage({ onLoggedIn }) {
  const [role, setRole] = useState('user');
  const [mode, setMode] = useState('log-in');
  const [form, setForm] = useState({ name: '', email: '', password: '', invite_code: '' });
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const set = (field) => (e) => setForm({ ...form, [field]: e.target.value });
  const client = role === 'admin' ? adminApi : api;

  function choose(nextRole, nextMode) {
    setRole(nextRole); setMode(nextMode); setError('');
  }

  async function submit(event) {
    event.preventDefault();
    setBusy(true); setError('');
    try {
      const { token } = mode === 'log-in'
        ? await client.logIn({ email: form.email, password: form.password })
        : await client.signUp(role === 'admin' ? form : { name: form.name, email: form.email, password: form.password });
      session.set({ role, token });
      onLoggedIn();
    } catch (e) { setError(e.message); }
    setBusy(false);
  }

  return (
    <div className="auth">
      <div className="auth-intro">
        <h2>A wallet where the database keeps the rules.</h2>
        <p className="muted">
          Every balance is the sum of immutable ledger entries. Fees, refunds, overdrafts and
          who-may-do-what are enforced inside PostgreSQL, not in this app.
        </p>
      </div>

      <section className="card auth-card">
        <div className="segmented">
          <button className={role === 'user' ? 'on' : ''} onClick={() => choose('user', mode)}>Wallet user</button>
          <button className={role === 'admin' ? 'on' : ''} onClick={() => choose('admin', mode)}>Admin</button>
        </div>

        <h3>{mode === 'log-in' ? 'Log in' : 'Create an account'}{role === 'admin' ? ' (admin)' : ''}</h3>
        <form onSubmit={submit}>
          {mode === 'sign-up' && <label>Name<input required value={form.name} onChange={set('name')} /></label>}
          <label>Email<input required type="email" value={form.email} onChange={set('email')} /></label>
          <label>Password<input required type="password" minLength={8} maxLength={72} value={form.password} onChange={set('password')} /></label>
          {mode === 'sign-up' && role === 'admin' && (
            <label>Admin invite code<input required value={form.invite_code} onChange={set('invite_code')} placeholder="invite-…" /></label>
          )}
          <button className="primary wide" disabled={busy}>
            {busy ? '…' : mode === 'log-in' ? 'Log in' : role === 'admin' ? 'Create admin account' : 'Create wallet'}
          </button>
          {error && <p className="error">{error}</p>}
        </form>

        <p className="muted switch">
          {mode === 'log-in'
            ? <>New here? <a href="#" onClick={(e) => { e.preventDefault(); choose(role, 'sign-up'); }}>Sign up</a></>
            : <>Already have an account? <a href="#" onClick={(e) => { e.preventDefault(); choose(role, 'log-in'); }}>Log in</a></>}
        </p>
        <p className="muted small-print">
          {role === 'user'
            ? <>Demo: <code>riya.demo@mini-ledger.test</code> or <code>kabir.demo@mini-ledger.test</code> / <code>demo-password</code>. A new wallet starts at ₹0.</>
            : <>Admin sign-up needs a single-use invite code from <code>npm run db:seed:logins</code>.</>}
          {' '}Five wrong passwords lock an email for 5 minutes.
        </p>
      </section>
    </div>
  );
}
