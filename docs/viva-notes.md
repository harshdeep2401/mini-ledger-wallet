# Viva notes

Short answers, each with the file or test to point at. The numbers come from your own runs. Money is simulated throughout.

---

## 1. The one-minute answer

**What is it?** A simulated wallet and payments system (add money, withdraw, transfer with a fee, refund). PostgreSQL itself guarantees that money cannot be created, lost, double-spent or silently edited, even if the application code is buggy.

**The key idea:** the business logic lives in the database. Every balance is the sum of immutable debit and credit entries. Every rule is a SQL function, constraint or trigger. The server's database logins cannot touch a single table.

**What does it show from the DBMS course?** Transactions and ACID, constraints, triggers (including deferred ones), stored functions, GRANT/REVOKE and roles, row locking, deadlock avoidance, idempotency, indexing, keyset pagination, query plans with EXPLAIN, controlled denormalisation, an audit check (reconciliation), LISTEN/NOTIFY, and hashing with pgcrypto.

---

## 2. Tech stack

| Layer | Technology | Why |
|---|---|---|
| Database | **PostgreSQL 18** on **Neon** (serverless Postgres) | Real transactions, row locks, deferred triggers, PL/pgSQL, roles, LISTEN/NOTIFY |
| Database code | SQL and **PL/pgSQL**, extension **pgcrypto** (bcrypt, random bytes) | The rules live next to the data |
| Server | **Node.js 24** with **Express 5** and **node-postgres (`pg`)** | A thin HTTP layer: one database function per request |
| Client | **React 19** with **Vite** | Log-in page, user dashboard, admin dashboard, demo console |
| Live updates | PostgreSQL `LISTEN/NOTIFY` → Server-Sent Events | The database pushes each committed transaction |
| Tests | Plain SQL test files run by `npm run test:db` | Each test runs in a transaction and rolls back |

---

## 3. Structure of the application

```
client/  (React)          server/  (Express)               db/  (PostgreSQL)
  auth/     log-in page     app.js     user routes            01–08  ledger core and roles
  wallet/   user dashboard  admin.js   admin routes           09–11  directory, demo reads, monitor
  admin/    admin dashboard live.js    LISTEN → SSE           12     user log-in
  demo/     demo console    simulator.js  simulated traffic   13     admin log-in
                            demo/      scripted demo acts
tests/   SQL tests (13 files)     demos/  concurrency races     scripts/  apply, reset, seeds, logins
```

**Screens:**
- **Log-in / sign-up:** choose Wallet user or Admin.
- **User dashboard:** balance; Add money, Withdraw and Transfer (the fee is shown before you confirm); recent activity, with refunds on transfers you received.
- **Admin → Dashboard:** live totals, the `BANK = wallets + fees` check, live reconciliation, the traffic simulator, the live transaction feed, the transaction tracer, the wallet list with freeze/unfreeze, and the full ledger check.
- **Admin → Demo console:** scripted acts played with **Next step**, each showing the function called, the input, the output, the ledger legs and the balances. It also has the concurrency races and the performance numbers.

---

## 4. Where the business logic lives

**In the database, and only there.**

| Rule | Where |
|---|---|
| Fee: 0.5%, min ₹1, max ₹10, round half up | `calculate_fee()` in `db/04_operations.sql` |
| No overdraft, no frozen accounts, debits = credits | `post_transaction()` (`db/03_posting.sql`) and triggers (`db/02_triggers.sql`) |
| Refunds: transfers only, capped at the original amount, fee kept | `refund()` |
| No double charge on retry | `db/05_idempotency.sql` |
| Who can do what | `db/08_roles.sql`, `db/12_auth.sql`, `db/13_admin_auth.sql` |

**What does the server do, then?** For each request it takes a pooled connection, runs `BEGIN`, calls exactly one database function with bound parameters, runs `COMMIT`, and maps the database error code to an HTTP status (`server/db.js`, `server/app.js`). It has no `if balance < amount` anywhere.

**Why?** A rule in app code can be skipped by a bug, a second client or a direct SQL session. A rule in the database cannot. Demo: "Try to break the ledger".

**What about the React app?** It only displays data and collects input. Even the fee shown before you confirm comes from `calculate_fee()`.

---

## 5. Data model and accounting

**Tables:**
- **Ledger:** `users`, `accounts`, `transactions`, `ledger_entries`, `idempotency_keys`.
- **Log-in:** `user_credentials`, `sessions`, `admins`, `admin_sessions`, `admin_invites`.

The diagram is in `docs/er-diagram.md`.

**Double-entry:** every movement is recorded twice, once where the money left and once where it arrived, so total debits always equal total credits. A missing or invented rupee shows up as an imbalance.

| Account | Type | Increases with |
|---|---|---|
| `BANK` | asset | debit |
| each user wallet | liability (the platform owes it to the user) | credit |
| `FEE_INCOME` | income | credit |

**What does each operation post?**

| Operation | Debit | Credit |
|---|---|---|
| Top-up | BANK | wallet |
| Withdrawal | wallet | BANK |
| Transfer | sender: amount + fee | recipient: amount; FEE_INCOME: fee |
| Refund | recipient | sender (the fee is not returned) |

**The equation that always holds:** BANK = all wallets + FEE_INCOME. The admin dashboard shows the difference live (₹0).

**Why integer paise?** Floats cannot store 0.1 exactly. `BIGINT` paise are exact and fast.

**Why is ₹4,500 charged ₹10?** The fee is capped at ₹10, and 0.5% reaches ₹10 at ₹2,000.

**Normal form?** Mostly 3NF. `accounts.cached_balance` is the one deliberate exception: a derived value kept for speed. Reading it takes 0.15 ms; recomputing the busiest account took 64 ms. `post_transaction()` keeps it in step, and reconciliation proves it is right.

**Why is `ledger_entries` an associative entity?** Transactions and accounts are many-to-many. The entry resolves that, and carries the link's own data (`direction`, `amount`).

**Why are passwords kept out of `users`?** The profile table stays free of secrets, and admins are a separate table, so a user can never become an admin by mistake.

---

## 6. How a payment works under the hood

A user clicks **Transfer ₹500 to Kabir**:

1. React creates an **idempotency key** for that click and sends `POST /api/me/transfers` with `Authorization: Bearer <token>` and `Idempotency-Key: <key>`. The request has no "from" field.
2. Express takes a `ledger_web` connection from the pool: `BEGIN`, then `SELECT ledger.my_transfer($1, $2, $3, $4)`, then `COMMIT`.
3. Inside PostgreSQL, in one transaction:
   1. `authenticate(token)` finds the user from the SHA-256 of the token, then their wallet.
   2. `check_idempotency` takes an advisory lock on the key. If the key was already used for the same request, the saved transaction id is returned.
   3. `calculate_fee(50000)` gives 250 paise.
   4. `post_transaction` locks both wallets and FEE_INCOME **in ascending id order** (`SELECT … FOR UPDATE`), checks the status and the balance, and inserts the transaction and its 3 legs.
   5. It updates the cached balances and records the idempotency key.
   6. At `COMMIT`, the **deferred trigger** checks that debits = credits. The **NOTIFY trigger** then announces the transaction.
4. The server forwards the NOTIFY to open admin dashboards as a Server-Sent Event, and the payment appears in the live feed.

**If anything fails**, the whole transaction rolls back: no legs, no key and no notification. The database error code becomes an HTTP status.

| SQLSTATE | Meaning | HTTP status |
|---|---|---|
| `P1001` | Business rule | 422 (409 for "already in progress") |
| `P1002` | Not logged in | 401 |
| `42501` | Permission denied | 403 |
| `40P01` / `40001` | Deadlock / serialization failure | 409 |
| class `22` | Bad input | 400 |

**Is there SQL injection risk?** No. The server never builds SQL from request text; every value is a bound parameter.

**Why are timestamps passed as text?** JavaScript dates hold milliseconds, but the history cursor needs microseconds.

---

## 7. DBMS concepts used

| Concept | Where in this project |
|---|---|
| **Transactions / ACID** | Every request is one transaction; a payment is all-or-nothing |
| **Constraints** | PK, FK, UNIQUE, CHECK (`amount > 0`, currency INR, a wallet is a liability, user XOR code) |
| **Triggers** | Append-only protection; account status guard; NOTIFY on commit |
| **Deferred constraint trigger** | Debits = credits, checked at `COMMIT` |
| **Stored functions (PL/pgSQL)** | All operations, reads, log-in, admin actions |
| **SECURITY DEFINER + pinned `search_path`** | Functions run with the owner's rights; callers need no table access |
| **GRANT / REVOKE, roles, least privilege** | 5 roles, function-only grants, closed by default |
| **Row-level locking** | `SELECT … FOR UPDATE` before the balance check |
| **Deadlock avoidance** | Lock accounts in a global (ascending id) order |
| **Advisory locks** | Two identical requests at the same instant |
| **Idempotency** | Key table plus request fingerprint, written in the same transaction |
| **Indexing** | `(account_id, created_at DESC, id DESC)` on entries |
| **Keyset pagination** | History paging by `(created_at, id)` cursor |
| **Query plans** | `EXPLAIN (ANALYZE, BUFFERS)` evidence in `docs/explain/` |
| **Denormalisation** | `cached_balance`, audited by reconciliation |
| **Audit / integrity check** | `reconciliation_issues()` re-adds every entry |
| **LISTEN / NOTIFY** | Live feed, delivered only on commit |
| **Sequences** | Identity ids; gaps appear because rolled-back inserts still use a value |
| **Hashing (pgcrypto)** | bcrypt passwords; SHA-256 tokens and invite codes |

---

## 8. Concurrency

**Isolation level?** PostgreSQL's default, READ COMMITTED, plus explicit row locks where it matters.

**Show me a race (double-spend).** Two ₹800 withdrawals hit a ₹1,000 wallet at once.
- The broken demo function reads the balance, waits, then writes without a lock. Both pass, and the balance ends at −₹600.
- The real function locks the row first (`FOR UPDATE`), so the second waits. When it continues it sees ₹200 and is refused.

`demos/concurrency.mjs`, `docs/concurrency.md`.

**How is the race made reproducible?** The broken functions sleep one second between the check and the write.

**Why `FOR UPDATE` rather than SERIALIZABLE?** Both are correct. Pessimistic locks never need retry logic; SERIALIZABLE aborts one side and the app must retry.

**What stops two refunds over-claiming at once?** `refund()` locks the original transaction row before adding up what has already been refunded, so concurrent refunds run one after the other.

**Is the live dashboard safe while 20 requests a second run?** Yes. The simulator keeps up to 8 requests in flight against the same 30 wallets, and the `BANK = wallets + fees` difference stays ₹0 with reconciliation green.

---

## 9. Deadlocks

**What is a deadlock?** Transfer A→B locks A then waits for B. At the same moment B→A locks B then waits for A. Each waits for the other, and PostgreSQL aborts one with `40P01`.

**Why can't it happen here?** `post_transaction()` always locks accounts in ascending id order, whatever the direction of the transfer. With a global lock order, a cycle cannot form.

**Proof:** the broken demo deadlocks; the real function ran 20 opposite transfers with 0 failures.

---

## 10. Idempotency

**The problem:** the network drops after `COMMIT` but before the response, and the client retries.

**The fix:** each click carries an `Idempotency-Key`. The key is stored in the **same transaction** as the payment, with a SHA-256 fingerprint of the operation and arguments.

| Case | Result |
|---|---|
| Same key, same request | The saved transaction id comes back; no second charge |
| Same key, different request | Refused ("already used for a different request") |
| Two at the same instant | An advisory lock lets one through; the other gets "already in progress" (409) |
| The payment failed | No key is stored, so a retry can still succeed |

Demo: eight sessions with one key give one transaction and seven refusals. The simulator also replays old keys ("Retries replayed").

---

## 11. Indexing and pagination

**The index:** `(account_id, created_at DESC, id DESC)` on `ledger_entries`. The equality column comes first, then the sort columns, so an account's rows are already stored in the order the history query wants, and `LIMIT 20` stops after 20 rows. `id` breaks ties, which keeps the cursor stable.

**Results (127,000 transactions, 374,000 entries):**

| Query | Without | With |
|---|---|---|
| History page | 89 ms (sequential scan and sort) | 0.15 ms (index), about 600× faster |
| Page 5,000 | OFFSET: 225 ms | keyset: 0.09 ms |
| Balance | recompute: 64 ms | cached: 0.15 ms |

**Why is OFFSET slow?** It must produce and throw away every skipped row.

**Why is keyset fast?** `WHERE (created_at, id) < cursor` jumps straight to the right place in the index, so page 5,000 costs the same as page 1.

**How was it measured?** `ANALYZE` first, then `EXPLAIN (ANALYZE, BUFFERS)`, three runs each, reporting the warm runs. `docs/performance.md`, `docs/explain/`, `npm run db:explain`.

**Does paging miss or repeat rows?** `npm run db:check-history` walks the busiest account's whole history and checks that every entry appears exactly once.

---

## 12. Security: roles and GRANT

| Role | Login? | Can do |
|---|---|---|
| `ledger_owner` | no | Owns every table and function |
| `ledger_web` | yes, used by the browser routes | Only token functions: `my_*` (own wallet) and `admin_*` (admin token checked first) |
| `ledger_app` | yes, used by internal tools (demo console, simulator, tests) | Unscoped money and read functions |
| `ledger_admin` | yes, used by the live-feed listener | Monitor reads, freeze/unfreeze, reconciliation |
| `ledger_reporting` | yes, optional | Reads and reconciliation |

- No role has any table privilege; each gets `USAGE` on the schema and `EXECUTE` on named functions.
- New functions are closed to PUBLIC by default (`ALTER DEFAULT PRIVILEGES`).
- Proof: `tests/08_roles.sql`, `tests/13_auth.sql`, `tests/14_admin_auth.sql`.

**What is `SECURITY DEFINER`?** The function runs with its owner's rights, so the caller needs no access to the tables. `search_path` is pinned so a caller cannot slip in a look-alike object from their own schema.

**Why a separate `ledger_web`?** `ledger_app` can name any wallet, which internal tools need. The browser must not, so its login can only call functions that take the wallet from a session token.

**What does the owner login do at runtime?** Only the fixed attack and tamper statements in the demo console. The attacks always roll back, and the tamper is repaired.

---

## 13. Log-in, for users and admins

- **Passwords:** bcrypt via pgcrypto (`crypt`, `gen_salt('bf')`). Passwords are 8–72 characters, because bcrypt reads only 72 bytes.
- **Sessions:** a random 32-byte token is returned once. Only its SHA-256 is stored. Sessions expire after 8 hours, and logging out revokes them.
- **Lockout:** 5 wrong passwords lock the email for 5 minutes. An unknown email gets the same answer as a wrong password.
- **Why does `log_in` return failure as a value instead of raising?** Raising an exception would roll back the failure count it just saved.
- **Own wallet only:** `my_transfer(token, recipient, …)` finds the sender from the token. Only the receiver can refund. The recipient search shows a masked email and no balance.
- **Admins** are a separate table with separate sessions:
  - sign-up needs a **single-use invite code**, stored hashed and created only by the owner;
  - every admin action first checks an **admin** token, so a user token gets 401;
  - the live feed, simulator and demo console routes call `admin_me(token)` first.

---

## 14. Reconciliation and live monitoring

**What does reconciliation check?** Working from the entries alone, independent of the posting code:
- global debits = credits;
- each transaction balances;
- each cached balance equals the recomputed one;
- no forbidden negative balances;
- each idempotency key matches its transaction;
- refund totals stay within the original transfer.

It is one read-only statement, so it sees one consistent snapshot. It takes about 1 second on the large ledger.

**Does it prevent damage?** No, it detects it. Prevention is the triggers and roles. Demo: corrupt a cached balance and the check reports "expected 100000, actual 99999999".

**How does the live feed work?**
1. An `AFTER INSERT` trigger on `transactions` calls `pg_notify`.
2. PostgreSQL delivers it only when the transaction **commits**, so rejected payments never appear.
3. The server keeps one `LISTEN` connection, on Neon's direct address, because the connection pooler cannot hold a LISTEN.
4. It fetches exactly the announced ids (commits can arrive out of order) and pushes them to the browser.

**Why do ids skip numbers in the feed?** A rejected payment rolled back, but its identity value was already used; sequences are never rolled back.

---

## 15. Testing and evidence

- **13 SQL test files** (`npm run test:db`). Each runs in a transaction and rolls back, so nothing is left behind.
- **They cover:** triggers, posting, operations, idempotency, reads and paging, reconciliation, roles, seed data, the closed demo functions, the read functions, the admin monitor, user log-in and admin log-in.
- **Concurrency demos:** `npm run demo:concurrency` runs each race 5 times against a broken and a real version, printing PASS/FAIL.
- **Performance evidence:** `docs/explain/*.txt`, `docs/performance.md`.
- **Each guarantee → what enforces it → which test proves it:** `docs/invariants.md`.

---

## 16. Honest limitations (say these first)

- **Simulation only.** No real money, bank or UPI. The UPI layer (VPA, PIN, collect requests) was skipped by decision; it adds no new ledger guarantees.
- **Log-in is simulated.** There is no email verification, password reset or 2FA. The browser keeps the token in sessionStorage.
- **The owner login or a superuser can disable triggers.** No ordinary route uses the owner login.
- **History is ordered by the transaction's start time**, so a slow transaction can commit behind a client's cursor.
- **Refunds keep the fee**, by design.
- **The performance numbers come from one Neon free-tier compute, warm cache.** The busiest account (120,000 entries) is an extreme case.
- **Reconciliation takes about a second**, so it runs every 10 s on the dashboard, not on every request.
- **The simulator runs inside the server process.** It is a load generator for the demo, not part of the ledger.

---

## 17. Likely follow-up questions

- *Why not just store a balance column?* An update leaves no trail and can be silently wrong. Entries are evidence.
- *What if the server crashes mid-payment?* The transaction rolls back: nothing is half-posted and no key is stored, so a retry is safe.
- *What if two transfers go in opposite directions?* Ordered locking (section 9).
- *How do you stop a user calling admin routes?* Every admin function checks an admin token from a separate table (`tests/14_admin_auth.sql` tries all 10 with no token, a bogus token and a user token).
- *How would you scale it?* Partition `ledger_entries` by time, keep the cached balance, and send reporting to a read replica as `ledger_reporting`.
- *What would you add next?* Password reset and 2FA, and the UPI layer.
