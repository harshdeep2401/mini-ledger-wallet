// The saved measurements from docs/performance.md (1,000 wallets, 127,000 transactions,
// 374,000 entries, Neon free tier, steady warm timings). Static: re-measuring needs the
// big seed, so the demo shows the saved evidence instead.
export const performance = {
  dataset: '1,000 wallets · 127,000 transactions · 374,000 ledger entries',
  comparisons: [
    { title: 'Last 20 entries of the busiest account',
      a: { label: 'Without the index', ms: 89, note: 'Reads all 374,000 entries, sorts 120,000' },
      b: { label: 'With the (account, time, id) index', ms: 0.15, note: 'Index scan, stops after 20 rows' },
      verdict: 'About 600× faster' },
    { title: 'Page 5,000 of the history',
      a: { label: 'OFFSET 100000', ms: 225, note: 'Builds and discards 100,000 rows' },
      b: { label: 'Keyset (created_at, id) < cursor', ms: 0.09, note: 'Jumps straight to the position' },
      verdict: 'About 2,500× faster, and the same cost on page 1 as on page 5,000' },
    { title: 'Reading a balance',
      a: { label: 'Recompute from 120,000 entries', ms: 64, note: 'Grows with the account\'s history' },
      b: { label: 'Cached balance', ms: 0.15, note: 'One primary-key read' },
      verdict: 'About 430× faster, and reconciliation proves the cache is honest' },
  ],
  reconciliation: { ms: 950, text: 'The whole ledger (127,000 transactions, 374,000 entries) is verified in about one second.' },
  source: 'docs/performance.md and docs/explain/',
};
