import { useEffect, useState } from 'react';
import { api, formatRupees } from './api.js';

// Search-as-you-type wallet chooser. The newest wallets are listed first, and typing
// searches every wallet by name or email, so a wallet just created is never lost
// in a long scrolling list.
export default function WalletPicker({ label, value, onChange, excludeId }) {
  const [text, setText] = useState('');
  const [results, setResults] = useState([]);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open) return undefined;
    let cancelled = false;
    const timer = setTimeout(() => {
      api.wallets(text, 12).then((rows) => !cancelled && setResults(rows)).catch(() => {});
    }, 200);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [text, open]);

  if (value) {
    return (
      <div className="picker">
        <span className="picker-label">{label}</span>
        <div className="picked">
          <span><b>{value.name}</b> <span className="muted">#{value.account_id} · {formatRupees(value.balance)}</span></span>
          <button type="button" className="small" onClick={() => { onChange(null); setText(''); }}>Change</button>
        </div>
      </div>
    );
  }

  return (
    <div className="picker">
      <span className="picker-label">{label}</span>
      <input value={text} placeholder="Search by name or email, or pick a recent wallet"
        onFocus={() => setOpen(true)} onChange={(e) => { setText(e.target.value); setOpen(true); }} />
      {open && (
        <ul className="picker-list">
          {results.filter((w) => String(w.account_id) !== String(excludeId)).map((w) => (
            <li key={w.account_id} onMouseDown={() => { onChange(w); setOpen(false); }}>
              <span><b>{w.name}</b> <span className="muted">#{w.account_id} · {w.email}</span></span>
              <span>{formatRupees(w.balance)}</span>
            </li>
          ))}
          {results.length === 0 && <li className="muted">No wallets found</li>}
        </ul>
      )}
    </div>
  );
}
