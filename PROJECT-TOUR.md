# Project Tour: what you're building and how you'll demo it

This is the "big picture" companion to `ledger-wallet-project.md`. That file is the **spec**. This one is the **story**: what the finished project looks like, what your professor will see, in what order, and what to say at each step.

> **Status (final scope):** the UPI layer (VPA, PIN, collect requests, RRN, daily limit) was **skipped by decision**; those parts below are marked *skipped* and kept only as context. The API lives in `server/`, the UI in `client/`, and the demo is run from the **Demo console** following [`docs/demo-script.md`](docs/demo-script.md).

Read it once now to get a feel for the project, then again on Day 3 when you rehearse.

---

## 1. The one-sentence pitch

> "It's a mini payments backend where the **database itself** guarantees money can't be created, lost, double-spent or silently edited, even if the application code is buggy."

Presented as a **payment simulator**: users pay each other, get a transaction reference, and can be refunded. It is not connected to any bank, payment network, or real money. (A UPI-style skin with VPAs, PINs and collect requests was planned and then *skipped*.)

Everything in the demo exists to prove that sentence. Keep coming back to it.

---

## 2. What the finished project looks like

```
mini-ledger-wallet/
├── db/                         ← THE GRADED PART
│   ├── 01_schema.sql           tables, CHECK / UNIQUE / FK constraints
│   ├── 02_triggers.sql         balance check, append-only, frozen-account guard
│   ├── 03_posting.sql          post_transaction()
│   ├── 04_operations.sql       top_up, transfer, withdraw, refund, fee, freeze
│   ├── 05_idempotency.sql      idempotency keys
│   ├── 06_reads.sql            get_balance, get_history, history index
│   ├── 07_reconciliation.sql   the "is the ledger healthy?" check
│   ├── 08_roles.sql            app / reporting / admin roles + privileges
│   ├── 09_wallet_directory.sql list_wallets
│   └── 10_demo_reads.sql       get_transaction, account_overview
├── tests/                      SQL tests (npm run test:db)
├── demos/
│   ├── concurrency.mjs         double-spend, deadlock, idempotency (broken vs fixed)
│   ├── seed.sql                demo seed (Alice and Bob)
│   └── sql/                    the deliberately broken demo functions
├── server/                     thin Express API + demo engine
├── client/                     React app + Demo console
└── docs/                       decisions, invariants, concurrency, performance,
                                ER diagram, demo script, viva notes
```

**What to remember:** roughly 80% of your marks sit in `db/` and `demos/`. The API and UI exist so the demo looks good and so you can show that "the app can't cheat even if it wanted to".

---

## 3. The features, grouped the way you'll present them

### A. Money movements (the "happy path")
| Feature | What the user sees | What happens in the ledger |
|---|---|---|
| Create user + wallet | New wallet with ₹0 | Rows in `users` and `accounts` |
| Top-up ₹1000 | Balance becomes ₹1000 | Debit **Bank** 1000, credit **Alice** 1000 |
| Transfer ₹500 + ₹2.50 fee (0.5%) | Alice −502.50, Bob +500 | Debit Alice 502.50, credit Bob 500, credit **Fee Income** 2.50 |
| Withdraw ₹200 | Balance drops by 200 | Debit Alice 200, credit Bank 200 |
| Refund (full/partial) | Money goes back | A **new** transaction whose entries mirror the original; the original is never edited |
| Freeze / unfreeze | Account greyed out | Status column changes; trigger blocks postings while frozen |

### B. Reads
- **Balance:** read from the cached column (fast), and it always matches the sum of entries.
- **History:** paginated list of a wallet's entries, using keyset pagination.

### C. Safety guarantees (the part that impresses professors)
| Guarantee | Enforced by |
|---|---|
| Every transaction balances (debits = credits) | Deferred constraint trigger, checked at `COMMIT` |
| History can't be rewritten | Trigger blocks `UPDATE`/`DELETE`, and the privileges are revoked from the app role |
| No negative amounts | `CHECK (amount > 0)` |
| No overdraft | Check inside the posting logic, on a locked account row |
| Frozen accounts can't move money | Trigger on `ledger_entries` insert |
| Retry doesn't charge twice | Idempotency table + `UNIQUE` key |
| Refund can't exceed the original | Check in `refund()` against the sum of previous refunds |
| Cached balances are honest | Reconciliation function |

### D. Engineering proof
- Two **concurrency bugs** reproduced and then fixed (double-spend, deadlock).
- **Indexing** before/after with `EXPLAIN ANALYZE` on 1M rows.
- **OFFSET vs keyset** pagination timing on deep pages.

---

## 4. The demo: a 20–25 minute script

Have three windows open side by side:
1. **Browser** with the frontend
2. **psql** terminal connected to the DB
3. The console's **Concurrency** page (replaces the terminal)

### Act 0: Pitch and architecture (1–2 min)
Show the architecture diagram and say:
> "The frontend calls the API, the API calls exactly one database function per request, and that's it. The API has no `if balance < amount` anywhere. All rules live in Postgres."

Then show the ER diagram briefly, focusing on `transactions` (1) → (many) `ledger_entries` (many) → (1) `accounts`.

### Act 1: The happy path in the UI (3 min)
1. Create **Alice** and **Bob**.
2. Top up Alice by ₹1000.
3. Transfer ₹500 Alice → Bob. Point out the ₹2.50 fee (0.5%, minimum ₹1, maximum ₹10).
4. Open Alice's history, then Bob's.
5. **Switch to psql** and show the raw entries for that transfer:
   ```sql
   SELECT a.name, e.direction, e.amount
   FROM ledger_entries e JOIN accounts a ON a.id = e.account_id
   WHERE e.transaction_id = <id>;
   ```
   ```
    name        | direction | amount
   -------------+-----------+--------
    alice       | debit     |  50250
    bob         | credit    |  50000
    fee_income  | credit    |    250
   ```
   > "Three legs, 502.50 out and 502.50 in. Amounts are in paise, so they're integers and never floats."
6. Click **"Check ledger"** in the UI → ✅ *Debits = credits, all cached balances match.*

### Act 1b: The UPI-style flow *(skipped)*
VPAs, PINs and RRNs were not built. Skip this act.

### Act 2: Idempotency, the double-click (1–2 min)
1. In the UI, **double-click** "Send" quickly (or use the "send twice" debug button).
2. Show that only **one** transaction was created.
   > "The frontend generates one idempotency key per click. The second request hits the same key and gets back the stored response instead of a second charge."
3. Optional, in psql: call `transfer()` with the **same key but a different amount** → rejected.

### Act 3: "Try to break it": the database says no (4 min)
This is the strongest part of the demo. Do it all **in psql**, playing a buggy or malicious developer.

| You try… | The DB responds |
|---|---|
| `UPDATE ledger_entries SET amount = 1 WHERE id = 1;` | ❌ `ledger_entries is append-only` |
| `DELETE FROM ledger_entries;` (as app role) | ❌ `permission denied` |
| Insert a debit of 100 with no matching credit, then `COMMIT` | ❌ fails **at commit**: `transaction 42 unbalanced: debits 100 ≠ credits 0` |
| Insert an entry with `amount = -50` | ❌ `CHECK` violation |
| Withdraw ₹5000 from a ₹497.50 wallet | ❌ `insufficient funds` |
| Freeze Bob in the UI, then send him money | ❌ `account is frozen` |

> "Even if the API had a bug, none of these could reach the ledger."

**Explain the deferred trigger here:** the check waits until `COMMIT` because while you're inserting the legs one at a time, the transaction is *temporarily* unbalanced, and that's fine. It only has to balance by the end.

### Act 4: Refunds (2 min)
1. Refund ₹200 of the ₹500 transfer (partial).
2. Show the new transaction with `reverses_transaction_id` pointing at the original. The original rows are untouched.
3. Try to refund ₹400 more → ❌ `refund exceeds remaining refundable amount (300)`.
4. Click "Check ledger" → still ✅.

### Act 4b: Collect requests *(skipped)*
Not built. Skip this act.

### Act 5: Reconciliation catches tampering (1 min)
As **admin**, deliberately corrupt the cached balance:
```sql
UPDATE accounts SET cached_balance = 99999999 WHERE name = 'alice';
```
Click "Check ledger" → ❌ *Alice: cached 99999999, actual 29750.*
> "The cached column is only for speed. The truth is the sum of the entries, and reconciliation proves it."

(Then fix it back.)

### Act 6: Concurrency, break then fix (4 min)
Run these from the console's **Concurrency** page (`demos/concurrency.mjs`); the samples below are the idea, the real output shows each session's INPUT and OUTPUT.

**Double-spend:**
```
$ python demos/double_spend.py --mode broken
Wallet balance: ₹1000
Thread 1: withdraw ₹800 → OK
Thread 2: withdraw ₹800 → OK
Final balance: -₹600   ❌ money created from nothing
```
```
$ python demos/double_spend.py --mode fixed
Thread 1: withdraw ₹800 → OK
Thread 2: withdraw ₹800 → insufficient funds
Final balance: ₹200    ✅
```
> "Both threads read ₹1000 before either wrote. `SELECT … FOR UPDATE` makes the second one wait for the first to commit, and then it sees ₹200."

**Deadlock:**
```
$ python demos/deadlock.py --mode broken
ERROR: deadlock detected   ❌
$ python demos/deadlock.py --mode fixed
200 transfers each way, 0 deadlocks ✅
```
> "A→B locks A then B; B→A locks B then A, so each waits for the other. The fix is to always lock the lower account id first, so the cycle can't form."

### Act 6b (stretch): A payment fails halfway *(skipped)*
Not built.

### Act 7: Performance (2–3 min)
Show the saved outputs (don't run 1M-row seeding live):

| Query | Before index | After index on `(account_id, created_at, id)` |
|---|---|---|
| Last 20 entries for one account | Seq Scan, ~300 ms | Index Scan, ~0.1 ms |

| Pagination (page 5000) | Time |
|---|---|
| `OFFSET 100000 LIMIT 20` | ~80 ms (reads and discards 100k rows) |
| Keyset `WHERE (created_at, id) < (…) LIMIT 20` | ~0.1 ms |

*(Your real numbers will differ. Use what you measure.)*

### Closing (30 sec)
> "Money is never a number I update. It's the sum of immutable entries, and Postgres refuses anything that doesn't balance, rewrites history, overdraws, or double-charges. Every rule is enforced by the database, not by the app."

---

## 5. Likely viva questions (prepare these)

**Accounting**
- Why is a user wallet a *liability*? → The platform owes that money to the user.
- Why does a credit *increase* a wallet? → Liabilities grow on the credit side.
- Where does top-up money "come from"? → The platform's Bank asset account (debit).

**Design**
- Why not just store a `balance` column and update it? → Updates leave no audit trail and can be silently wrong. Entries are evidence.
- Then why keep a cached balance at all? → Speed. Reconciliation keeps it honest.
- Why integers, not `NUMERIC` or `FLOAT`? → Floats can't represent 0.1 exactly. Integer paise is exact and fast.
- What normal form is the schema in? Is `cached_balance` a violation? → Mostly 3NF. The cache is *deliberate, controlled denormalisation*, so explain the trade-off.
- Why is the balance trigger *deferred*? → Legs are inserted one at a time, so balance can only be checked at commit.

**Concurrency**
- What's a race condition? Show me one. → Act 6.
- Why `FOR UPDATE` and not just `SERIALIZABLE`? → Both work. Pessimistic locking never needs retries; serializable needs retry logic. (Bonus benchmark if you did it.)
- Why does lock ordering prevent deadlock? → A deadlock needs a cycle in the wait graph, and a global ordering makes cycles impossible.

**Idempotency**
- What if the network drops after the DB commits but before the client gets the response? → Client retries with the same key and gets the stored response, with no double charge.
- What if two identical requests arrive at the *same instant*? → `UNIQUE` key: one inserts the key "in flight", the other gets a conflict.

**Indexing**
- Why that column order `(account_id, created_at, id)`? → Equality column first, then the sort columns. `id` breaks ties for stable keyset pagination.
- Why is OFFSET slow on deep pages? → It still reads and throws away all the skipped rows.

**UPI layer** *(skipped)*
- Why is there no UPI layer? → It was a product skin over the same ledger; it adds no new ledger guarantees, and the time went into the database, the concurrency demos and the evidence.

**AI-assisted parts**
- Walk me through what happens when I click "Send". → UI generates a key → POST /transfer → API opens a connection, calls `transfer(...)` in one transaction, returns the JSON → UI updates. Be ready to point at the exact lines.

---

## 6. Mini-glossary (for learning as you go)

| Term | Plain meaning |
|---|---|
| **Double-entry** | Every movement is recorded twice: where it left and where it arrived |
| **Debit / Credit** | Just "left side / right side" of an entry; whether it increases or decreases depends on account type |
| **Asset / Liability** | Something the platform owns / something it owes |
| **Ledger entry** | One leg of a transaction: one account, one direction, one amount |
| **Append-only** | You can add rows, never change or remove them |
| **Reversing transaction** | Fixing a mistake by posting the opposite entries, not by editing |
| **Idempotency** | Doing the same request twice has the same effect as doing it once |
| **Deferred constraint** | A check that runs at `COMMIT` instead of after each statement |
| **`SELECT … FOR UPDATE`** | Read a row *and lock it* so others wait until you're done |
| **Deadlock** | Two transactions each waiting for a lock the other holds |
| **Keyset pagination** | "Give me 20 rows after this one" instead of "skip N rows" |
| **Reconciliation** | Re-computing totals from scratch to prove the shortcuts are right |
| **PL/pgSQL** | Postgres's built-in programming language for functions and triggers |

---

## 7. Suggested learning order

You don't need to know everything up front. Learn each concept right before you build it:

1. **Debits and credits on paper.** Write the entries for top-up, transfer, withdraw and refund by hand. *(Most important hour of the project.)*
2. **Basic SQL DDL:** `CREATE TABLE`, `CHECK`, `UNIQUE`, `FOREIGN KEY`.
3. **Triggers:** first a simple `BEFORE UPDATE` that raises an error, then a `CONSTRAINT TRIGGER … DEFERRABLE INITIALLY DEFERRED`.
4. **PL/pgSQL functions:** variables, `IF`, `RAISE EXCEPTION`, `RETURNING`.
5. **Transactions and locking:** `BEGIN`/`COMMIT`, `FOR UPDATE`. Reproduce a race with two psql windows *before* writing the Python script.
6. **Indexes and `EXPLAIN ANALYZE`:** learn to read "Seq Scan" vs "Index Scan".
7. **Roles and `GRANT`/`REVOKE`.**
8. **Then** generate the API and UI on top of the finished functions.

---

## 8. Demo-day checklist

- [ ] Fresh DB loads from `db/*.sql` with one command (e.g. `make reset`)
- [ ] Demo users seeded, with Alice at a known balance
- [ ] psql snippets for Act 3 saved in a file to copy-paste
- [ ] `EXPLAIN ANALYZE` outputs saved as text or screenshots (don't seed 1M rows live)
- [ ] Concurrency scripts tested at least 5 times in a row
- [ ] Reconciliation shows ✅ at the start and the end
- [ ] README states clearly: **simulation only, no real money**
- [ ] You can explain every file in `server/` and `client/` line by line
