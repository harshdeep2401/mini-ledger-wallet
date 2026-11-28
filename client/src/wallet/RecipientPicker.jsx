import { useEffect, useState } from 'react';
import { api } from '../api.js';

// Search-as-you-type chooser for who to pay. The database returns only a name and a
// masked email (never a balance), and leaves out the logged-in user.
// Search by part of a name, or by someone's full email address.
export default function RecipientPicker({ value, onChange }) {
  const [text, setText] = useState('');
  const [results, setResults] = useState([]);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open) return undefined;
    let cancelled = false;
    const timer = setTimeout(() => {
      api.recipients(text).then((rows) => !cancelled && setResults(rows)).catch(() => {});
    }, 200);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [text, open]);

  if (value) {
    return (
      <div className="picker">
        <span className="picker-label">To</span>
        <div className="picked">
          <span><b>{value.name}</b> <span className="muted">{value.masked_email} · #{value.account_id}</span></span>
          <button type="button" className="small" onClick={() => { onChange(null); setText(''); }}>Change</button>
        </div>
      </div>
    );
  }

  return (
    <div className="picker">
      <span className="picker-label">To</span>
      <input value={text} placeholder="Name or full email address"
        onFocus={() => setOpen(true)} onBlur={() => setTimeout(() => setOpen(false), 150)}
        onChange={(e) => { setText(e.target.value); setOpen(true); }} />
      {open && (
        <ul className="picker-list">
          {results.map((r) => (
            <li key={r.account_id} onMouseDown={() => { onChange(r); setOpen(false); }}>
              <span><b>{r.name}</b> <span className="muted">{r.masked_email}</span></span>
              <span className="muted">#{r.account_id}</span>
            </li>
          ))}
          {results.length === 0 && <li className="muted">No one found</li>}
        </ul>
      )}
    </div>
  );
}
