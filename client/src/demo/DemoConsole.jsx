import { useEffect, useState } from 'react';
import { demoApi } from '../api.js';
import ScenarioPlayer from './ScenarioPlayer.jsx';
import ConcurrencyPanel from './ConcurrencyPanel.jsx';
import PerformancePanel from './PerformancePanel.jsx';
import Intro from './Intro.jsx';

// The presenter's console: a list of acts on the left, the chosen act on the right.
export default function DemoConsole() {
  const [scenarios, setScenarios] = useState([]);
  const [error, setError] = useState('');
  const [current, setCurrent] = useState({ kind: 'intro' });

  useEffect(() => {
    demoApi.scenarios().then(setScenarios).catch((e) => setError(e.message));
  }, []);

  const groups = [];
  for (const s of scenarios) {
    let group = groups.find((g) => g.name === s.group);
    if (!group) { group = { name: s.group, items: [] }; groups.push(group); }
    group.items.push(s);
  }

  const isActive = (kind, id) => current.kind === kind && current.id === id;

  return (
    <div className="console">
      <nav className="acts card">
        <button className={`act ${current.kind === 'intro' ? 'on' : ''}`} onClick={() => setCurrent({ kind: 'intro' })}>
          Start here
        </button>
        {groups.map((group) => (
          <div key={group.name}>
            <h4>{group.name}</h4>
            {group.items.map((s) => (
              <button key={s.id} className={`act ${isActive('scenario', s.id) ? 'on' : ''}`}
                onClick={() => setCurrent({ kind: 'scenario', id: s.id })}>
                {s.title}
              </button>
            ))}
          </div>
        ))}
        <h4>Engineering proof</h4>
        <button className={`act ${current.kind === 'concurrency' ? 'on' : ''}`} onClick={() => setCurrent({ kind: 'concurrency' })}>
          Concurrency
        </button>
        <button className={`act ${current.kind === 'performance' ? 'on' : ''}`} onClick={() => setCurrent({ kind: 'performance' })}>
          Performance
        </button>
        {error && <p className="error">{error}</p>}
      </nav>

      <div className="stage">
        {current.kind === 'intro' && <Intro />}
        {current.kind === 'scenario' && <ScenarioPlayer key={current.id} scenarioId={current.id} />}
        {current.kind === 'concurrency' && <ConcurrencyPanel />}
        {current.kind === 'performance' && <PerformancePanel />}
      </div>
    </div>
  );
}
