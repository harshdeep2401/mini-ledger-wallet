import { useRef, useState } from 'react';
import { streamText } from '../api.js';

const DEMOS = [
  { id: 'double-spend', title: 'Double-spend', text: 'Two ₹800 withdrawals race against a ₹1,000 wallet.' },
  { id: 'deadlock', title: 'Deadlock', text: 'A→B and B→A transfers race each other.' },
  { id: 'idempotency', title: 'Idempotency', text: 'The same request sent many times at once.' },
];

// Colours one line of the demo's text output by what it is.
function lineClass(line) {
  if (/INPUT/.test(line)) return 'line-input';
  if (/OUTPUT\s+ERROR/.test(line)) return 'line-error';
  if (/OUTPUT/.test(line)) return 'line-output';
  if (/^\s*PASS/.test(line)) return 'line-pass';
  if (/^\s*FAIL/.test(line)) return 'line-fail';
  if (/---|^===|^Double-spend|^Deadlock|^Idempotency/.test(line)) return 'line-head';
  if (/✗/.test(line)) return 'line-fail';
  if (/✓/.test(line)) return 'line-output';
  return 'line-dim';
}

export default function ConcurrencyPanel() {
  const [running, setRunning] = useState(null);
  const [output, setOutput] = useState('');
  const [error, setError] = useState('');
  const outRef = useRef(null);

  async function run(id) {
    setRunning(id); setOutput(''); setError('');
    try {
      await streamText(`/api/demo/concurrency/${id}`, (chunk) => {
        setOutput((text) => text + chunk);
        queueMicrotask(() => outRef.current?.scrollTo(0, outRef.current.scrollHeight));
      });
    } catch (e) { setError(e.message); }
    setRunning(null);
  }

  return (
    <section className="card">
      <h2>Concurrency: broken vs real</h2>
      <div className="demo-grid">
        {DEMOS.map((d) => (
          <div key={d.id} className="demo-card">
            <h4>{d.title}</h4>
            <p className="muted">{d.text}</p>
            <button className="primary" disabled={running !== null} onClick={() => run(d.id)}>
              {running === d.id ? 'Running…' : 'Run'}
            </button>
          </div>
        ))}
      </div>
      {error && <p className="error">{error}</p>}
      <div className="legend">
        <span className="line-input">INPUT</span>
        <span className="line-output">OUTPUT</span>
        <span className="line-error">ERROR</span>
      </div>
      {(output || running) && (
        <pre className="terminal" ref={outRef}>
          {output ? output.split('\n').map((line, i) => <div key={i} className={lineClass(line)}>{line || ' '}</div>) : 'Starting…'}
        </pre>
      )}
    </section>
  );
}
