# Implementation Plan: Database Layer

A step-by-step path from an empty folder to a finished database layer. Each phase builds on the one before it, so do them in order.

**How to use this file**
- Each phase lists **what to build**, the **decisions** to make first (marked 🧭, bring these to Claude), what **Codex** can help with, and a **done-when** checklist.
- Don't start a phase until the previous phase's done-when list is all ticked.
- Write down every 🧭 decision and the reason for it in `docs/decisions.md`. That file is your viva preparation.

**Who does what**

| You (by hand) | Codex (easy or repetitive code) | Claude (architecture) |
|---|---|---|
| Tables, constraints, triggers, PL/pgSQL functions, indexes, roles | Reset script, test harness, bulk seed generators, Python race scripts, API and frontend | 🧭 decisions, reviewing your SQL, debugging, explaining errors |

The spec says the database layer is written by hand and graded, so keep Codex away from `db/0*.sql`. Using it to look up syntax is fine. Having it write your triggers is not.

---

## Phase 0: Setup (≈1 hour)

**Build**
- Create a PostgreSQL project on Neon and a database called `ledger` (or record the database name Neon provides).
- Install a PostgreSQL client such as `psql` locally so you can connect to Neon. A local PostgreSQL server is optional.
- Save the Neon connection string in a local `.env` file; never commit credentials. The repository `.gitignore` already excludes `.env` files.
- Create the folder layout:
  ```
  db/        01_schema.sql, 02_triggers.sql, 03_posting.sql, ... (numbered, run in order)
  tests/     one test file per phase
  demos/     concurrency + performance
  docs/      decisions.md, invariants.md, ...
  ```
- Write a **setup script** that connects to the existing Neon database and applies `db/*.sql` in order. Use `psql -v ON_ERROR_STOP=1` so the first error stops the run. Do not drop and recreate a Neon database as part of routine setup.

**Codex can:** write the reset script and a Makefile (`make reset`, `make test`).

**Done when**
- [ ] The setup command applies the database files to the intended Neon database
- [ ] You can connect to Neon with `psql`

---

## Phase 1: Paper design (≈1–2 hours)

This is the debit/credit exercise from earlier. Finish it before writing any SQL. See [Phase 1 Tutorial](tutorials/phase-1-paper-design.md).

**Done when**
- [ ] The entries for top-up, transfer with fee, withdrawal, full refund and partial refund are written down and balance
- [ ] Each account type has a balance formula
- [ ] Claude has reviewed your answers

---

## Phase 2: Core schema (≈2–3 hours) → `db/01_schema.sql`

**Build:** the tables `users`, `accounts`, `transactions` and `ledger_entries`. Leave out `idempotency_keys` for now.

🧭 **Decisions**
1. **Primary keys:** `bigint generated always as identity` or `uuid`? This affects lock ordering (Phase 4) and keyset pagination (Phase 7).
2. **Enumerated values** such as account type, direction and status: a Postgres `ENUM` type, or `text` with a `CHECK (... IN (...))`?
3. **Sign convention for `cached_balance`:** always stored "in the account's normal direction", or always credits − debits?
4. **Currency:** you have one currency, INR. Do you still add a `currency` column with a CHECK, or leave it out?
5. **How to mark system accounts** (Bank, Fee Income): give them a nullable `user_id`, a `kind` column, or something else?

**Constraints to include now:** primary keys, foreign keys, `NOT NULL`, `CHECK (amount > 0)`, and the valid values for type, status and direction. Use `timestamptz` for every timestamp.

**Tests** (`tests/02_schema.sql`): inserting an entry with `amount = 0` fails, an entry pointing at an account that doesn't exist fails, and an invalid status fails.

**Codex can:** write the test harness pattern. That is a `DO` block that runs a statement, catches the expected error, and raises `'TEST FAILED'` if no error happened. Write this pattern once and reuse it in every later phase.

**Done when**
- [ ] Schema loads cleanly
- [ ] Tests for invalid input pass (each bad insert is rejected)
- [ ] Rough ER diagram sketched (it can be on paper for now)
- [ ] Normalization notes started. Note why `cached_balance` is deliberate denormalization.

---

## Phase 3: Invariant triggers (≈3–4 hours) → `db/02_triggers.sql`

This is the riskiest phase, so build the deferred trigger first.

**Build, in this order**
1. **Balance check:** debits must equal credits for each transaction. Write it as a `CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED` so it runs at `COMMIT`.
2. **Append-only:** a trigger that raises an error on any `UPDATE` or `DELETE` of `ledger_entries`.
3. **Account status guard:** block inserting an entry for a `frozen` or `closed` account.

🧭 **Decisions**
6. **Per-row or per-statement balance trigger?** A row-level deferred trigger checks the same transaction once for every leg it has, and the 1M-row seed in Phase 10 will feel that cost. A statement-level trigger with transition tables avoids it but is harder to write. Pick one now, knowing about Phase 10.
7. **Should the frozen guard block both debits and credits?** Think about what a refund *to* a frozen account should do.
8. **Is `transactions` append-only too?** If it has a `status` column, decide which changes to that column are legal.

**Tests**
- An unbalanced transaction fails **at `COMMIT`**, not at the `INSERT`. Test this explicitly; it is the point of making the trigger deferred.
- A balanced 3-leg transaction commits.
- `UPDATE` and `DELETE` on `ledger_entries` both fail.
- Posting to a frozen account fails.

**Done when**
- [ ] All of the above tests pass in `make reset`
- [ ] You can explain to someone why the balance trigger has to be deferred

---

## Phase 4: The posting function (≈3–4 hours) → `db/03_posting.sql`

This is the most important function in the project. Every operation in Phase 5 calls it. In one go, it should: lock the affected accounts, check for overdrafts, insert the `transactions` row and its entries, and update the cached balances.

🧭 **Decisions** (discuss these with Claude before writing any code)
9. **How are legs passed in?** A `jsonb` array, parallel arrays, or a composite type array? Weigh it up by how readable it is, how strict the types are, and how easy it is to call from Python.
10. **Where is `cached_balance` updated?** Inside this function, or by a trigger on `ledger_entries`? One choice means everything that writes entries keeps the cache in step; the other is more explicit and easier to follow.
11. **Lock ordering:** lock with `SELECT ... FOR UPDATE ... ORDER BY id`, before any checks run. Confirm you understand why the order of locking matters (Phase 11 depends on it).
12. **Overdraft check:** is it done in this function after locking, or in a trigger? It must look at the balance *after* the lock is taken.
13. **The "broken" version for the demos:** how will you show double-spend and deadlock without breaking the real code? Options: a separate function that skips the locks and lives in a `demo` schema, or a parameter. *(Recommendation: a separate function in a `demo` schema, so the production function has no "unsafe" switch.)*

**Tests:** posting a balanced set of legs works, an overdraft is rejected, cached balances match after posting, and the frozen account check still fires.

**Done when**
- [ ] One function handles every kind of posting
- [ ] Nothing else in `db/` inserts into `ledger_entries` directly

---

## Phase 5: Operation functions (≈3–4 hours) → `db/04_operations.sql`

**Build:** `create_user_with_wallet`, `top_up`, `transfer`, `withdraw`, `refund`, `freeze_account`, `unfreeze_account`. Each one should do little more than work out its legs and call the posting function from Phase 4.

🧭 **Decisions**
14. **Fee policy:** a flat fee, a percentage, or a minimum plus a percentage? Where is it configured: a constant, a `settings` table, or a function argument? How does rounding work with paise?
15. **Refunds:** does a refund return the fee? How do you find the amount still refundable, and what stops two refunds running at the same time from both getting past the cap? *(Hint: what do you lock?)*
16. **Return values:** what does each function return? A transaction id, a row, or `jsonb`? The API in Phase 12 depends on this, so be consistent across all functions.

**Tests:** every scenario from Phase 1 is reproduced in SQL and the balances match your paper version. Also test: a refund over the cap fails, a refund of a refund fails, and transferring to yourself fails (unless you decide otherwise).

**Done when**
- [ ] Every scenario from Phase 1 produces the same balances as on paper

---

## Phase 6: Idempotency (≈2–3 hours) → `db/05_idempotency.sql`

**Build:** the `idempotency_keys` table, and a way for every money-moving function to accept a key.

🧭 **Decisions** (this is the subtlest design in the project)
17. **Where is the request hash computed?** Compute it inside the database from the function's arguments, so no logic leaks into the API.
18. **What does "in flight" mean?** If the key row and the money movement are written in the **same** transaction, a second request with that key **waits** on the unique index until the first one commits, and then sees the finished result. In that case no one ever sees an "in flight" state. To get a real "conflict, still processing" response, the key has to be committed separately first. Decide which design you want and be ready to explain the trade-off.
19. **What gets stored when an operation fails** (for example, insufficient funds)? Should a retry with the same key replay the error, or try again?

**Tests:** the same key with the same payload returns the stored result and creates no new transaction. The same key with a different payload is rejected. Concurrent requests with the same key are tested in Phase 11.

**Done when**
- [ ] Calling `transfer` twice with the same key creates exactly one transaction

---

## Phase 7: Read functions (≈1–2 hours) → `db/06_reads.sql`

**Build:** `get_balance(account_id)`, and `get_history(account_id, cursor, limit)` using keyset pagination.

🧭 **Decisions**
20. **The cursor:** use the pair `(created_at, id)`. Why isn't `created_at` enough on its own?
21. **History rows:** what should each row show? Just the entry, or also the other side of the transaction ("to Bob")?

**Done when**
- [ ] Paging through all of an account's history returns every entry exactly once, with no duplicates or gaps

---

## Phase 8: Reconciliation (≈1 hour) → `db/07_reconciliation.sql`

**Build:** a view or function that reports (a) whether total debits equal total credits across the whole ledger, and (b) any account whose `cached_balance` doesn't match the sum of its entries.

🧭 **Decision**
22. **The output shape:** a single pass/fail boolean, or one row per problem found? The UI's "Check ledger" button uses this.

**Tests:** on a clean database it passes. Corrupt one `cached_balance` as a superuser and it reports exactly that account.

---

## Phase 9: Roles and privileges (≈2 hours) → `db/08_roles.sql`

**Build:** three roles: `ledger_app`, `ledger_reporting` and `ledger_admin`, plus an owner role that owns the tables.

🧭 **Decisions**
23. **What can the app role do?** The strongest design is: the app role can **only `EXECUTE` your functions** and has no direct table access, while the functions are `SECURITY DEFINER` and owned by the owner role. Then "the API never touches a balance" is enforced by the database, not just a team rule. If you use `SECURITY DEFINER`, you **must** set `search_path` on those functions, so ask Claude why.
24. **What can reporting read?** Everything, or only the views?

**Tests:** connected as `ledger_app`, a direct `INSERT`, `UPDATE` or `DELETE` on any table fails, and calling `transfer(...)` works.

---

## Phase 10: Seed data and performance (≈2–3 hours) → `db/09_seed.sql`, `demos/perf_seed.sql`

**Build**
- A small demo seed: system accounts, Alice, Bob and a few transactions.
- A large seed of about 1M balanced entries using `generate_series`, which must still pass reconciliation afterwards.
- `EXPLAIN ANALYZE` on the history query **before** and **after** creating the index on `(account_id, created_at, id)`.
- `OFFSET` pagination compared with keyset pagination on a deep page.

🧭 **Decision**
25. **How the bulk seed meets your triggers:** insert in batches through the triggers, use one large set-based insert, or temporarily disable the triggers as admin and then prove the data is valid with reconciliation? Your answer to decision 6 matters here.

**Codex can:** write the `generate_series` query that creates the data (you check that it balances), and the scripts that capture `EXPLAIN` output to files.

**Done when**
- [ ] The before/after plans and timings are saved in `docs/performance.md`

---

## Phase 11: Concurrency demos (≈3–4 hours) → `demos/`

**Build**
- **Double-spend:** two ₹800 withdrawals race against a ₹1000 wallet. Run it with the unsafe function from decision 13 (both succeed), then with the real function (one fails).
- **Deadlock:** A→B and B→A transfers race each other. Without lock ordering they deadlock; with it they don't.
- **Idempotency race:** the same key is sent from two threads at once, and exactly one transaction is created.
- **Bonus:** a throughput comparison between `FOR UPDATE` and `SERIALIZABLE` isolation with retries.

**Do this first by hand:** reproduce each race in two psql windows before scripting it, so you see the locks actually wait.

**Codex can:** write the Python threading or psycopg harness. You decide which SQL each thread runs.

**Done when**
- [ ] Each demo produces the same result 5 times in a row
- [ ] The output is written up in `docs/concurrency.md`

---

## Phase 12: API and frontend (Codex-led)

Give Codex your final function signatures from `db/` and these rules:
- Each endpoint calls exactly one database function and contains no business logic.
- Each request gets a connection from a pool, runs in one transaction, and returns the connection.
- The frontend generates one idempotency key per user action.

**Your job:** read every line it produces until you can explain it in the viva.

---

## Phase 13: Documentation

`docs/er-diagram`, `docs/invariants.md` (each guarantee, the database object that enforces it, and the test that proves it), `docs/decisions.md`, `docs/performance.md`, `docs/concurrency.md`, the demo script, and the README with the simulation disclaimer.

---

## 🧭 Decision log template (`docs/decisions.md`)

```
## D<n>: <question>
Options considered: ...
Chosen: ...
Why: ...
Consequence / trade-off: ...
```

Twenty-five decisions, each written up like this, will cover most of your viva.

---

## Where to start right now

Finish **Phase 0 and Phase 1**. Then bring decisions **1–5** (Phase 2) to Claude before writing `01_schema.sql`.
