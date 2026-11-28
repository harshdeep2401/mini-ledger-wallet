import { useEffect, useRef, useState } from 'react';
import { adminApi, formatRupees, streamEvents } from '../api.js';

const MAX_ROWS = 60;

// Transactions pushed by PostgreSQL (LISTEN/NOTIFY -> server -> Server-Sent Events).
export default function LiveFeed({ selectedId, onSelect }) {
  const [rows, setRows] = useState([]);
  const [status, setStatus] = useState('connecting');
  const [paused, setPaused] = useState(false);
  const [fresh, setFresh] = useState(new Set());
  const pausedRef = useRef(false);
  pausedRef.current = paused;

  useEffect(() => {
    adminApi.feed(30).then(setRows).catch(() => {});
    const controller = new AbortController();

    function onEvent(name, data) {
      if (name === 'ready') setStatus('live');
      if (name === 'failed') setStatus('failed');
      if (name !== 'transactions' || pausedRef.current) return;
      const incoming = data;
      setRows((old) => {
        const seen = new Set(old.map((r) => r.transaction_id));
        const added = incoming.filter((r) => !seen.has(r.transaction_id));
        return [...added, ...old]
          .sort((a, b) => Number(b.transaction_id) - Number(a.transaction_id))
          .slice(0, MAX_ROWS);
      });
      setFresh(new Set(incoming.map((r) => r.transaction_id)));
    }

    // Keep the stream open; reconnect after a drop (the admin token is sent as a header).
    (async () => {
      while (!controller.signal.aborted) {
        try {
          await streamEvents('/api/admin/events', onEvent, controller.signal);
        } catch { /* dropped or aborted */ }
        if (controller.signal.aborted) return;
        setStatus('reconnecting');
        await new Promise((r) => setTimeout(r, 3000));
      }
    })();
    return () => controller.abort();
  }, []);

  return (
    <section className="card">
      <div className="between">
        <h3 style={{ margin: 0 }}>
          Live transactions <span className={`live ${status}`}>{status === 'live' ? '● LIVE' : status}</span>
        </h3>
        <button className="small" onClick={() => setPaused(!paused)}>{paused ? 'Resume' : 'Pause'}</button>
      </div>
      <p className="muted">Only committed transactions appear. A rejected payment rolls back and is never announced.</p>
      <div className="feed">
        <table className="compact">
          <thead>
            <tr><th>#</th><th>Time</th><th>Type</th><th>From → To</th><th className="right">Amount</th><th className="right">Fee</th></tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr
                key={r.transaction_id}
                className={`${fresh.has(r.transaction_id) ? 'fresh' : ''} ${selectedId === r.transaction_id ? 'picked' : ''}`}
                onClick={() => onSelect(r.transaction_id)}
              >
                <td>{r.transaction_id}</td>
                <td>{new Date(r.created_at).toLocaleTimeString()}</td>
                <td><span className={`type ${r.type}`}>{r.type}</span></td>
                <td>{r.from_label} → {r.to_label}</td>
                <td className="right">{formatRupees(r.amount)}</td>
                <td className="right">{Number(r.fee) ? formatRupees(r.fee) : ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
