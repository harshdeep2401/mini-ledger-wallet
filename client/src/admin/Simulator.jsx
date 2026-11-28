import { useEffect, useState } from 'react';
import { adminApi } from '../api.js';

// Start/stop the traffic simulator and show what the database accepted or refused.
export default function Simulator() {
  const [sim, setSim] = useState(null);
  const [rate, setRate] = useState(5);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    let alive = true;
    const load = () => adminApi.simulator().then((s) => alive && setSim(s)).catch(() => {});
    load();
    const t = setInterval(load, 1000);
    return () => { alive = false; clearInterval(t); };
  }, []);

  async function toggle() {
    setBusy(true); setError('');
    try {
      setSim(sim?.running ? await adminApi.stopSimulator() : await adminApi.startSimulator(rate));
    } catch (e) { setError(e.message); }
    setBusy(false);
  }

  const c = sim?.counts;
  return (
    <section className="card">
      <div className="between">
        <h3 style={{ margin: 0 }}>Traffic simulator</h3>
        <div className="actions" style={{ margin: 0 }}>
          <select value={rate} onChange={(e) => setRate(Number(e.target.value))} disabled={sim?.running} style={{ width: 'auto', margin: 0 }}>
            {[2, 5, 10, 20].map((r) => <option key={r} value={r}>{r} / sec</option>)}
          </select>
          <button className={sim?.running ? 'danger' : 'primary'} onClick={toggle} disabled={busy || sim?.starting}>
            {sim?.starting || (busy && !sim?.running) ? 'Creating users…' : sim?.running ? 'Stop' : 'Start'}
          </button>
        </div>
      </div>
      <p className="muted">
        {sim?.running
          ? `${sim.users} simulated users, ${sim.rate} requests/sec, ${sim.inFlight} in flight.`
          : 'Simulated users paying each other as ledger_app. Some requests are meant to fail.'}
      </p>
      {error && <p className="error">{error}</p>}

      {c && c.attempted > 0 && (
        <>
          <div className="tiles small">
            <div className="tile"><div className="tile-label">Sent</div><div className="tile-value">{c.attempted}</div></div>
            <div className="tile good"><div className="tile-label">Accepted</div><div className="tile-value">{c.accepted}</div></div>
            <div className="tile bad"><div className="tile-label">Rejected by DB</div><div className="tile-value">{c.rejected}</div></div>
            <div className="tile"><div className="tile-label">Retries replayed</div><div className="tile-value">{c.replayed}</div></div>
          </div>
          <table className="compact">
            <thead><tr><th>Action</th><th className="right">Accepted</th><th className="right">Rejected</th></tr></thead>
            <tbody>
              {Object.entries(sim.byKind).map(([kind, n]) => (
                <tr key={kind}><td>{kind}</td><td className="right">{n.accepted}</td><td className="right">{n.rejected}</td></tr>
              ))}
            </tbody>
          </table>
          {sim.rejections.length > 0 && (
            <>
              <h4 className="subhead">Latest rejections (database messages)</h4>
              <ul className="rejections">
                {sim.rejections.slice(0, 6).map((r) => (
                  <li key={r.at + r.message}><b>{r.action}</b> <span className="code">{r.code}</span> {r.message}</li>
                ))}
              </ul>
            </>
          )}
        </>
      )}
    </section>
  );
}
