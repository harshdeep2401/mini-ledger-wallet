# Concurrency demos (Phase 11)

Three races, each run against a deliberately broken version and against the real
function. Raw output of five consecutive runs: [`concurrency-output.txt`](concurrency-output.txt).
All money is simulated.

```sh
npm run demo:setup         # installs the broken demo.* functions (owner-only)
npm run demo:concurrency   # runs all three demos 5 times, prints PASS/FAIL
npm run demo:teardown      # removes the demo schema
```

Code: `demos/concurrency.mjs` (harness), `demos/sql/demo_functions.sql` (broken functions).
Each demo opens separate database connections so the sessions really run at the
same time. The broken functions take a one-second pause between their check and
their write, so the race happens every time instead of depending on luck.

**Result: 15 of 15 scenario runs passed (3 demos × 5 runs), with the same outcome every time.**

## 1. Double-spend

Two ₹800 withdrawals race against a ₹1,000 wallet.

| Version | Result |
|---|---|
| `demo.withdraw_unsafe` (reads the balance with no lock) | Both succeed. Wallet ends at **−₹600**. |
| `ledger.withdraw` | One succeeds, the other is refused: `insufficient funds: balance 20000, change -80000`. Wallet ends at ₹200. |

**Why:** the unsafe function checks the balance, waits, then writes. Both callers
read ₹1,000 before either wrote. The real function locks the wallet row
(`SELECT ... FOR UPDATE` inside `post_transaction`) *before* checking, so the second
caller waits, then sees ₹200 and is refused.

The unsafe run leaves a negative wallet. The harness repairs it with a normal
`top_up` (history is append-only, so we add a correcting entry), then confirms
`reconciliation_summary()` is healthy again.

## 2. Deadlock

A→B and B→A transfers race each other.

| Version | Result |
|---|---|
| `demo.transfer_unordered` (locks the sender first, then the recipient) | PostgreSQL aborts one with `40P01 deadlock detected`; the other completes. |
| `ledger.transfer` (10 rounds of opposite transfers, 20 total) | 0 failures. |

**Why:** unordered, A→B holds A and waits for B while B→A holds B and waits for A.
`post_transaction` always locks accounts in ascending id order, so both transfers
want the lowest id first; the second just queues behind the first.

## 3. Idempotency race

The same idempotency key arrives more than once at the same moment.

| Part | Result |
|---|---|
| Request A is open (not yet committed); request B arrives with the same key | B fails fast: `request with this idempotency key is already in progress`. |
| A commits; B retries | B gets the same transaction id back. |
| 8 connections fire the same key together | All that succeed return one transaction id; the rest are refused "already in progress". |
| Transactions with that key | Exactly 1 each time. |

**Why:** `check_idempotency` takes a transaction-scoped advisory lock on the key
(`pg_try_advisory_xact_lock`), so a second request cannot start while the first is
in flight. After the first commits, the saved key makes a retry a replay.
How many of the 8 requests succeed (they replay) versus fail fast varies from
run to run depending on timing; the invariant checked is that only **one transaction exists**.

## Notes and limits

- The `demo` schema is never created by `db:reset` or `db:apply`. `tests/10_demo_closed.sql`
  checks that `ledger_app`, `ledger_reporting`, `ledger_admin` and PUBLIC cannot use it.
- `npm run db:reset` removes the ledger but not the `demo` schema; re-run `npm run demo:setup`
  afterwards (or `demo:teardown` first) because the demo functions reference ledger objects.
- The demos create fresh users each run and leave them in the database.
- The optional `FOR UPDATE` vs `SERIALIZABLE` throughput comparison was skipped by choice.
