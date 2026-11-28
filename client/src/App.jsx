import { useEffect, useState } from 'react';
import { api, adminApi, session } from './api.js';
import AuthPage from './auth/AuthPage.jsx';
import UserDashboard from './wallet/UserDashboard.jsx';
import AdminShell from './admin/AdminShell.jsx';

// Not logged in -> log-in / sign-up page. A wallet user -> their dashboard.
// An admin -> the admin dashboard and demo console.
export default function App() {
  const [current, setCurrent] = useState(session.get());

  // The server answered 401 (expired, or logged out elsewhere): back to the log-in page.
  useEffect(() => {
    const ended = () => setCurrent(null);
    window.addEventListener('session-ended', ended);
    return () => window.removeEventListener('session-ended', ended);
  }, []);

  async function logOut() {
    await (current?.role === 'admin' ? adminApi : api).logOut().catch(() => {});
    session.set(null);
    setCurrent(null);
  }

  return (
    <div className="app">
      <header>
        <h1>Mini Ledger Wallet</h1>
        {current && <span className="chip role">{current.role === 'admin' ? 'Admin' : 'Wallet user'}</span>}
      </header>

      {!current && <AuthPage onLoggedIn={() => setCurrent(session.get())} />}
      {current?.role === 'user' && <UserDashboard onLogOut={logOut} />}
      {current?.role === 'admin' && <AdminShell onLogOut={logOut} />}

      <footer className="disclaimer">
        Simulation only. No real money, bank or UPI network is involved.
      </footer>
    </div>
  );
}
