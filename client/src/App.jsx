import { useState } from 'react';
import Wallets from './Wallets.jsx';
import WalletDetail from './WalletDetail.jsx';
import Pay from './Pay.jsx';
import Admin from './Admin.jsx';
import DemoConsole from './demo/DemoConsole.jsx';

const TABS = ['Demo console', 'Wallets', 'Pay', 'Ledger check'];

export default function App() {
  const [tab, setTab] = useState('Demo console');
  const [selected, setSelected] = useState(null); // a wallet row from /api/wallets
  const [version, setVersion] = useState(0);       // bump to make screens reload data
  const refresh = () => setVersion((v) => v + 1);

  return (
    <div className="app">
      <header>
        <h1>Mini Ledger Wallet</h1>
        <nav>
          {TABS.map((name) => (
            <button key={name} className={tab === name ? 'active' : ''} onClick={() => setTab(name)}>
              {name}
            </button>
          ))}
        </nav>
      </header>

      {tab === 'Demo console' && <DemoConsole />}
      {tab === 'Wallets' && (
        <div className="columns">
          <Wallets key={version} selected={selected} onSelect={setSelected} />
          {selected
            ? <WalletDetail key={`${selected.account_id}-${version}`} wallet={selected} onChanged={refresh} />
            : <section className="card muted">Pick a wallet to see its balance and history.</section>}
        </div>
      )}
      {tab === 'Pay' && <Pay key={version} initialSender={selected} onChanged={refresh} />}
      {tab === 'Ledger check' && <Admin />}

      <footer className="disclaimer">
        Simulation only. No real money, bank or UPI network is involved.
      </footer>
    </div>
  );
}
