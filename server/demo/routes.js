// /api/demo/*: the presenter's console. Scenario runs, the concurrency demos (streamed
// from demos/concurrency.mjs) and the saved performance numbers.
import { spawn } from 'node:child_process';
import path from 'node:path';
import express from 'express';
import { listScenarios, startRun, nextStep, abortRun, ledgerHealth } from './engine.js';
import { performance as performanceRows } from './performance.js';

export const demo = express.Router();
const route = (handler) => (req, res, next) => handler(req, res).catch(next);
const root = path.join(import.meta.dirname, '..', '..');

demo.get('/scenarios', (req, res) => res.json(listScenarios()));
demo.post('/runs', route(async (req, res) => res.status(201).json(await startRun(req.body?.scenario))));
demo.post('/runs/:id/next', route(async (req, res) => res.json(await nextStep(req.params.id))));
demo.delete('/runs/:id', route(async (req, res) => res.json(await abortRun(req.params.id))));
// Whole-ledger check. Slow on a big ledger (about a second), so the console asks for it
// separately and shows the step result first.
demo.get('/health', route(async (req, res) => res.json(await ledgerHealth())));
demo.get('/performance', (req, res) => res.json(performanceRows));

// Concurrency demos. The list is fixed, so nothing from the request reaches the command.
const CONCURRENCY = ['double-spend', 'deadlock', 'idempotency'];
let concurrencyBusy = false;

function runNode(args, onText) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, ['demos/concurrency.mjs', ...args], { cwd: root, env: { ...process.env, DEMO_VERBOSE: '1' } });
    child.stdout.on('data', (chunk) => onText(chunk.toString()));
    child.stderr.on('data', (chunk) => {
      const text = chunk.toString();
      if (!/SSL modes|libpq|trace-warnings|pg-connection-string|verify-full|sslmode|^\s*$|^To prepare|^- If/m.test(text)) onText(text);
    });
    child.on('close', resolve);
  });
}

demo.get('/concurrency/:name', route(async (req, res) => {
  const { name } = req.params;
  if (!CONCURRENCY.includes(name)) return res.status(404).json({ error: 'unknown concurrency demo' });
  if (concurrencyBusy) return res.status(409).json({ error: 'a concurrency demo is already running' });
  concurrencyBusy = true;
  res.set({ 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no' });
  res.flushHeaders();
  try {
    res.write('Installing the deliberately broken demo functions (owner-only)...\n');
    await runNode(['setup'], (t) => res.write(t));
    const code = await runNode([name, '1'], (t) => res.write(t));
    res.write(`\n[exit ${code}]\n`);
  } finally {
    concurrencyBusy = false;
    res.end();
  }
}));
