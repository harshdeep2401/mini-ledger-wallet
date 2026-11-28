import { useEffect, useState } from 'react';
import { adminApi } from '../api.js';
import AdminPage from './AdminPage.jsx';
import DemoConsole from '../demo/DemoConsole.jsx';

// Admin area: the live dashboard, or the scripted demo console.
export default function AdminShell({ onLogOut }) {
  const [me, setMe] = useState(null);
  const [view, setView] = useState('dashboard');

  useEffect(() => { adminApi.me().then(setMe).catch(() => {}); }, []);

  return (
    <div className="dashboard">
      <div className="topbar">
        <div>
          <div className="hello">Admin{me ? ` · ${me.name}` : ''}</div>
          <div className="muted">{me?.email}</div>
        </div>
        <div className="actions" style={{ margin: 0 }}>
          <div className="segmented">
            <button className={view === 'dashboard' ? 'on' : ''} onClick={() => setView('dashboard')}>Dashboard</button>
            <button className={view === 'demo' ? 'on' : ''} onClick={() => setView('demo')}>Demo console</button>
          </div>
          <button className="small" onClick={onLogOut}>Log out</button>
        </div>
      </div>
      {view === 'dashboard' ? <AdminPage /> : <DemoConsole />}
    </div>
  );
}
