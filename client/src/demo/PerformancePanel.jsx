import { useEffect, useState } from 'react';
import { demoApi } from '../api.js';

// Bar widths use a log scale: 0.1 ms and 200 ms must both be visible on one page.
const width = (ms, max) => `${Math.max(2, (Math.log10(ms * 100) / Math.log10(max * 100)) * 100)}%`;

export default function PerformancePanel() {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  useEffect(() => { demoApi.performance().then(setData).catch((e) => setError(e.message)); }, []);
  if (error) return <section className="card"><p className="error">{error}</p></section>;
  if (!data) return <section className="card muted">Loading…</section>;

  return (
    <section className="card">
      <h2>Performance</h2>
      <p className="muted">{data.dataset}</p>
      {data.comparisons.map((c) => {
        const max = Math.max(c.a.ms, c.b.ms);
        return (
          <div key={c.title} className="perf">
            <h4>{c.title}</h4>
            {[['slow', c.a], ['fast', c.b]].map(([kind, side]) => (
              <div key={side.label} className="perf-row">
                <div className="perf-label">{side.label}</div>
                <div className="perf-bar"><div className={`bar ${kind}`} style={{ width: width(side.ms, max) }} /></div>
                <div className="perf-ms">{side.ms} ms</div>
              </div>
            ))}
            <p className="ok">{c.verdict}</p>
          </div>
        );
      })}
      <p className="ok">Whole ledger verified in about {data.reconciliation.ms} ms</p>
    </section>
  );
}
