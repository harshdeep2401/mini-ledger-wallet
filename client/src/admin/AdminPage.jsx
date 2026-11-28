import { useState } from 'react';
import Dashboard from './Dashboard.jsx';
import Simulator from './Simulator.jsx';
import LiveFeed from './LiveFeed.jsx';
import Tracer from './Tracer.jsx';
import WalletDirectory from './WalletDirectory.jsx';
import LedgerCheck from './LedgerCheck.jsx';

// The admin monitor: totals, simulator, live feed and tracer, plus the full ledger check.
export default function AdminPage() {
  const [traced, setTraced] = useState(null);
  return (
    <div className="admin">
      <Dashboard />
      <div className="admin-grid">
        <LiveFeed selectedId={traced} onSelect={setTraced} />
        <div className="stage">
          <Simulator />
          <Tracer transactionId={traced} onSelect={setTraced} />
        </div>
      </div>
      <WalletDirectory />
      <LedgerCheck />
    </div>
  );
}
