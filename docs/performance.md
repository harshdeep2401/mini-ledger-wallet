# Performance measurements

Capture evidence only after `npm run db:seed:performance` has completed and
reported a healthy reconciliation:

```sh
npm run db:explain
```

The command runs `ANALYZE`, captures three `EXPLAIN (ANALYZE, BUFFERS)` runs per
query, and writes the raw output into `docs/explain/`. The first run shows the
cold-to-warm effect; compare the later runs for steady timings. It temporarily
drops the history index inside a transaction for the no-index plan and rolls
the DDL back before continuing. Run it while the database is otherwise idle.

The history query below isolates the indexed page access: it returns the entry
and transaction fields used by history, but omits the lateral other-party name
lookup so that index behavior is easier to compare. It uses the hot
`FEE_INCOME` account, which has one entry for each seeded transfer. The deep
page comparison uses the row at offset 99,999 as its cursor, so keyset returns
the same next 20 rows as `OFFSET 100000`.
The `get_balance` and reconciliation captures explain only the function call,
so they show total call timing but not the query plan inside each function.

| Experiment | Exact query | Evidence file | Warm timing | Plan summary / interpretation |
|---|---|---|---:|---|
| History page, index present | [`history-indexed-page.sql`](explain/queries/history-indexed-page.sql) | `history-with-index.txt` | 0.15 ms | Index scan on `idx_ledger_entries_account_history`, no sort step, 20 index rows read, 65 buffers. The index already stores the rows in the requested order, so `LIMIT 20` stops after 20. |
| Same history page, index temporarily absent | [`history-indexed-page.sql`](explain/queries/history-indexed-page.sql) | `history-without-index.txt` | 89 ms | Parallel sequential scan of all 374,000 entries (254,000 removed by the filter per run), then a sort of the 120,000 matches, then `LIMIT 20`. About 3,600 buffers. ~600× slower: it reads and sorts the whole account to return 20 rows. |
| `OFFSET 100000` page | [`history-offset-deep-page.sql`](explain/queries/history-offset-deep-page.sql) | `offset-deep-page.txt` | 225 ms | With the index present the planner still chose a parallel seq scan + hash join + sort: `OFFSET 100000` must produce and order 100,020 rows before discarding 100,000 of them. The index cannot help skip rows; ~4,700 buffers. |
| Keyset first page | [`history-indexed-page.sql`](explain/queries/history-indexed-page.sql) | `keyset-page-1.txt` | 0.15 ms | Same plan as the indexed page: index scan, 65 buffers. (Run 1 was 0.55 ms, a cold-cache effect.) |
| Keyset page after row 100,000 | [`history-keyset-deep-page.sql`](explain/queries/history-keyset-deep-page.sql) | `keyset-deep-page.txt` | 0.09 ms | Index condition `(created_at, id) < cursor` jumps straight to the position; 65 buffers, same as page 1. Cost does not grow with page depth, and it is ~2,500× faster than the OFFSET query for the same 20 rows. |
| Cached `get_balance` | [`balance-cached.sql`](explain/queries/balance-cached.sql) | `balance-cached.txt` | 0.15 ms | One primary-key read, 3 buffers. (Only the function call is visible, not the plan inside it.) |
| Recompute hot account balance from entries | [`balance-recomputed.sql`](explain/queries/balance-recomputed.sql) | `balance-recomputed.txt` | 64 ms | Sums 120,000 entries of the hot account; the planner used a seq scan over 374,000 rows (3,496 buffers). ~430× slower than the cached balance, and it grows with the account's history. |
| Full reconciliation summary | [`reconciliation.sql`](explain/queries/reconciliation.sql) | `reconciliation.txt` | ~950 ms | Whole-ledger verification of 127,000 transactions and 374,000 entries in one statement, ~26,000 buffers; temp read/written 806 blocks (some sort/hash work spilled to disk). |

## Dataset facts

The deterministic performance seed creates 1,000 wallets, 1,000 top-ups,
120,000 transfers and 6,000 withdrawals: 127,000 transactions and 374,000
ledger entries. Each wallet starts with ₹10,000. A wallet can be debited at
most 120 × ₹51 in transfers including fees, plus six ₹50 withdrawals, so its
generated outgoing total stays below its starting top-up even before counting
incoming transfers. Each transaction is posted by a database operation
function, so its ledger legs and cached balances use the normal production
path. The fee income account receives 120,000 entries, enough for the chosen
100,000-row deep-page comparison.

After the performance seed, run `npm run db:check-history` for the full
keyset walk. It checks that the fee account has more than 100,000 rows across
multiple timestamps and that the walk finds every entry exactly once.

`setup-facts.txt` records the row and relation sizes: `ledger_entries` is 64 MB
and its indexes 36 MB; the hot `FEE_INCOME` account has 120,000 entries. The
timings above are the steady values of runs 2–3 (run 1 is the cold run), captured
on 2026-11-22 on the Neon free tier. They depend on that compute tier.

## What the numbers show

- **The index is the difference.** The same history page takes 0.15 ms with the
  index and 89 ms without it (≈600×). Without it PostgreSQL reads every entry and sorts
  120,000 rows to return 20.
- **OFFSET gets slower with depth; keyset does not.** The deep page costs 225 ms
  with OFFSET and 0.09 ms with keyset, and keyset page 1 and page 5,000 behave the same.
- **Finding:** even with the index present, the planner chose a seq scan plus sort for
  `OFFSET 100000`. At that depth it has to produce 100,020 rows anyway, so the
  index no longer saves work. Only keyset avoids the work.
- **Why the cache exists.** Reading the cached balance is 0.15 ms; recomputing it
  from the hot account's entries is 64 ms and grows with history. Reconciliation is
  the correctness check for that cache, and it runs in about 1 s over the full ledger.
- **Limits of this evidence.** Every run shows `shared hit` only, meaning all data was
  in memory (the dataset is ~100 MB), so these are warm numbers. A much larger dataset
  would add disk reads. Timings are from one Neon compute tier and the hot account
  is an extreme case (120,000 entries); an ordinary wallet has a few hundred.
- **History walk.** `npm run db:check-history` returned all 120,000 fee-account entries
  exactly once across 1,200 distinct timestamps, so the `created_at` half of the cursor
  is now exercised.

The operation functions assign real transaction timestamps. The seed runs
committed batches, so separate batches receive different timestamps; these are
spread over the load duration, not synthetically across months. That is the
accepted Phase 10 choice in `docs/decisions.md`.
