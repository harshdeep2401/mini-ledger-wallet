import { useEffect, useRef, useState } from 'react';
import { demoApi, formatRupees } from '../api.js';

// Plays one scenario a step at a time. The presenter presses "Next step"; the result
// appears at once, and the (slower) whole-ledger check fills in a moment later.
export default function ScenarioPlayer({ scenarioId }) {
  const [run, setRun] = useState(null);       // response of POST /runs
  const [results, setResults] = useState([]); // one entry per step played
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const runIdRef = useRef(null);
  const [generation, setGeneration] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setRun(null); setResults([]); setError('');
    demoApi.start(scenarioId).then((started) => {
      if (cancelled) { demoApi.abort(started.run_id); return; }
      runIdRef.current = started.run_id;
      setRun(started);
    }).catch((e) => !cancelled && setError(e.message));

    const onUnload = () => runIdRef.current && demoApi.abort(runIdRef.current, { keepalive: true });
    window.addEventListener('beforeunload', onUnload);
    return () => {
      cancelled = true;
      window.removeEventListener('beforeunload', onUnload);
      if (runIdRef.current) { demoApi.abort(runIdRef.current); runIdRef.current = null; }
    };
  }, [scenarioId, generation]);

  if (error) return <section className="card"><p className="error">{error}</p></section>;
  if (!run) return <section className="card muted">Creating fresh demo wallets…</section>;

  const played = results.length;
  const finished = played >= run.steps.length;
  const latest = results.at(-1);

  async function next() {
    setBusy(true); setError('');
    try {
      const result = await demoApi.next(run.run_id);
      const index = results.length;
      setResults((all) => [...all, { ...result, healthState: 'checking' }]);
      demoApi.health()
        .then((health) => setResults((all) => all.map((r, i) => (i === index ? { ...r, health, healthState: 'done' } : r))))
        .catch(() => setResults((all) => all.map((r, i) => (i === index ? { ...r, healthState: 'failed' } : r))));
    } catch (e) { setError(e.message); }
    setBusy(false);
  }

  return (
    <div className="player">
      <section className="card">
        <div className="between">
          <div>
            <h2>{run.scenario.title}</h2>
          </div>
          <button onClick={() => setGeneration((g) => g + 1)} disabled={busy}>Restart</button>
        </div>
        <ol className="steps">
          {run.steps.map((step, i) => {
            const r = results[i];
            const state = r ? (stepOk(r) === false ? 'bad' : 'done') : i === played ? 'now' : 'todo';
            return (
              <li key={i} className={state}>
                <span className="mark">{r ? (stepOk(r) === false ? '⚠' : '✓') : i + 1}</span>
                {step.title}
                {step.expect === 'rejected' && <span className="chip">refused</span>}
              </li>
            );
          })}
        </ol>
        <div className="actions">
          <button className="primary" onClick={next} disabled={busy || finished}>
            {busy ? 'Running…' : finished ? 'Scenario finished' : `Next step: ${run.steps[played].title}`}
          </button>
        </div>
        {!finished && <p className="say">{run.steps[played].say}</p>}
        {error && <p className="error">{error}</p>}
      </section>

      {latest && <StepResult result={latest} />}
      {!latest && <AccountsCard before={run.accounts} after={run.accounts} />}
    </div>
  );
}

// true / false once everything is known, undefined while the ledger check is still running.
function stepOk(result) {
  if (!result.outcome_as_expected) return false;
  if (result.healthState === 'checking') return undefined;
  if (result.healthState === 'failed') return false;
  return result.health.healthy === result.expect_healthy;
}

function StepResult({ result }) {
  return (
    <>
      <section className="card result">
        <div className="between">
          <h3>{result.title}</h3>
          <span className={`badge ${result.outcome}`}>{result.outcome === 'accepted' ? 'ACCEPTED' : 'REFUSED'}</span>
        </div>
        {!result.outcome_as_expected && (
          <p className="warn">Not as expected: this step should have been {result.expect === 'rejected' ? 'refused' : 'accepted'}.</p>
        )}
        {result.notes.map((n, i) => <p key={i} className="ok">{n}</p>)}
        {result.rows.length > 0 && (
          <table className="kv"><tbody>{result.rows.map(([k, v], i) => <tr key={i}><td>{k}</td><td className="right">{v}</td></tr>)}</tbody></table>
        )}
        <HealthLine result={result} />
      </section>
      <section className="card">
        {result.trace.length === 0 && <p className="muted">Nothing sent to the database in this step.</p>}
        {result.trace.map((call, i) => <CallBlock key={i} call={call} />)}
      </section>
      {result.transaction && <LegsCard transaction={result.transaction} />}
      <AccountsCard before={result.before} after={result.after} />
    </>
  );
}

// One database call: the function called, the input we sent, and the output we got back.
function CallBlock({ call }) {
  const entries = Object.entries(call.input ?? {});
  const output = call.output;
  return (
    <div className="call">
      <div className="call-head">
        <span>{call.kind === 'function' ? `FUNCTION CALLED  ${call.function}(${entries.map(([k]) => k).join(', ')})` : call.function}</span>
        <span className="who">as {call.role} · {call.ms} ms</span>
      </div>
      <div className="call-row input">
        <span className="tagname">Input</span>
        {entries.length === 0 ? <span className="muted">none</span> : (
          <table className="args"><tbody>
            {entries.map(([k, v]) => (
              <tr key={k}><td>{k}</td><td>{Array.isArray(v) ? <pre>{v.join(';\n')}</pre> : String(v)}</td></tr>
            ))}
          </tbody></table>
        )}
      </div>
      <div className={`call-row output ${output?.ok ? 'good' : 'bad'}`}>
        <span className="tagname">Output</span>
        {output?.ok ? (
          <pre>{typeof output.value === 'object' ? JSON.stringify(output.value, null, 2) : String(output.value)}
            {call.returns ? <span className="muted">   ← {call.returns}</span> : null}</pre>
        ) : (
          <pre>ERROR{output?.code ? ` [${output.code}]` : ''}: {output?.message}</pre>
        )}
      </div>
    </div>
  );
}

function HealthLine({ result }) {
  if (result.healthState === 'checking') return <p className="muted">Checking ledger…</p>;
  if (result.healthState === 'failed') return <p className="error">Ledger check could not run.</p>;
  const { healthy, ms } = result.health;
  const expectedBad = !result.expect_healthy;
  return (
    <p className={healthy ? 'ok' : expectedBad ? 'caught' : 'error'}>
      {healthy ? '✅ Ledger healthy' : expectedBad ? '❌ Ledger check caught the problem' : '❌ Ledger check FAILED'}
      <span className="muted"> · {Math.round(ms)} ms</span>
    </p>
  );
}

function LegsCard({ transaction }) {
  const { legs, debits, credits } = transaction;
  const balanced = debits === credits;
  return (
    <section className="card">
      <h3>
        Ledger legs: transaction #{transaction.transaction_id}{' '}
        <span className="chip">{transaction.type}</span>
        {transaction.reverses_transaction_id && <span className="chip">reverses #{transaction.reverses_transaction_id}</span>}
      </h3>
      <table>
        <thead><tr><th>Account</th><th className="right">Debit</th><th className="right">Credit</th></tr></thead>
        <tbody>
          {legs.map((l, i) => (
            <tr key={i}>
              <td>{l.label}</td>
              <td className="right">{l.direction === 'debit' ? formatRupees(l.amount) : ''}</td>
              <td className="right">{l.direction === 'credit' ? formatRupees(l.amount) : ''}</td>
            </tr>
          ))}
          <tr className="total">
            <td>Total</td><td className="right">{formatRupees(debits)}</td><td className="right">{formatRupees(credits)}</td>
          </tr>
        </tbody>
      </table>
      <p className={balanced ? 'ok' : 'error'}>{balanced ? 'Debits = Credits ✅' : 'UNBALANCED'}</p>
    </section>
  );
}

function AccountsCard({ before, after }) {
  const beforeById = new Map(before.map((a) => [a.account_id, a]));
  return (
    <section className="card">
      <h3>Balances</h3>
      <table>
        <thead><tr><th>Account</th><th className="right">Before</th><th className="right">After</th><th className="right">Change</th></tr></thead>
        <tbody>
          {after.map((a) => {
            const b = beforeById.get(a.account_id)?.balance ?? a.balance;
            const delta = a.balance - b;
            return (
              <tr key={a.account_id} className={delta !== 0 ? 'changed' : ''}>
                <td>{a.label}{a.status === 'frozen' && <span className="tag"> frozen</span>}</td>
                <td className="right">{formatRupees(b)}</td>
                <td className="right"><b>{formatRupees(a.balance)}</b></td>
                <td className={`right ${delta > 0 ? 'pos' : delta < 0 ? 'neg' : 'muted'}`}>
                  {delta === 0 ? '·' : `${delta > 0 ? '+' : ''}${formatRupees(delta)}`}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </section>
  );
}
