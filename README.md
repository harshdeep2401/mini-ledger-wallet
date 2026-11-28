# Mini Ledger Wallet

A simulated payments backend in which **PostgreSQL itself** guarantees that money cannot be created, lost, double-spent or silently edited, even if the application code is buggy. It is built on a double-entry ledger, with a thin Express server and a React app on top.

> **Simulation only.** This project does not handle real money and is not connected to any bank, payment gateway or UPI network.

---

## Philosophy

1. **The database is the source of truth and the rule keeper.** Every money rule (balances, fees, refunds, account status, who may do what) lives in SQL functions, constraints and triggers. The server cannot skip a rule, because it has no way around the functions.
2. **Money is never a number you update.** A balance is the sum of immutable debit and credit entries. The `cached_balance` column is a fast copy that reconciliation can always re-check against the entries.
3. **Every transaction balances.** Debits equal credits, checked at commit by a deferred trigger. A half-written payment cannot commit.
4. **History is append-only.** Entries and transactions cannot be updated, deleted or truncated. Mistakes are corrected with new entries (refunds), never by editing old ones.
5. **Least privilege.** The server's database logins have no table access at all, only `EXECUTE` on approved functions.
6. **Thin application code.** Each HTTP endpoint opens a transaction, calls exactly one database function with bound parameters, and returns the result.
7. **Integers only.** Amounts are `BIGINT` paise (₹1 = 100 paise). No floating point anywhere.

---

## Architecture

```
┌──────────────────────┐     ┌───────────────────────────┐     ┌─────────────────────────────┐
│  React (client/)     │     │  Express (server/)        │     │  PostgreSQL / Neon (db/)    │
│                      │     │                           │     │                             │
│  Log in / sign up    │     │                           │     │  schema "ledger"            │
│  User dashboard ─────┼────►│  /api/auth, /api/me       ├────►│   tables: no role can touch │
│                      │     │      ledger_web (token)   │     │   SECURITY DEFINER funcs    │
│  Admin dashboard ────┼────►│  /api/admin               │     │   triggers, constraints     │
│                      │     │      ledger_web (admin    │     │                             │
│  Admin demo console ─┼────►│  /api/demo   token)       │     │                             │
│     ▲                │     │  simulator → ledger_app   │     │                             │
│     └─ live feed ◄───┼─SSE─┤  LISTEN ledger_events ◄───┼─────┤  NOTIFY on every commit    │
└──────────────────────┘     └───────────────────────────┘     └─────────────────────────────┘
 Admin-only routes first ask the database whether the admin token is valid (admin_me).
 The demo console also uses the owner login, for fixed attack/tamper statements that are always rolled back or repaired.
```

**One request, end to end (paying someone):**

1. The browser creates an idempotency key for the click and sends `POST /api/me/transfers` with `Authorization: Bearer <session token>` and `Idempotency-Key: <key>`.
2. The server takes a `ledger_web` connection and runs `BEGIN`, `SELECT ledger.my_transfer($1, $2, $3, $4)`, `COMMIT`.
3. Inside the database, the token is turned into the caller's wallet and the key is checked. The fee is calculated and the accounts are locked in id order. The legs are posted, and the deferred trigger checks debits = credits at commit.
4. The commit delivers `NOTIFY ledger_events`, which the server forwards to open Admin pages as a Server-Sent Event.

**Database logins (roles):**

| Role | Used by | Can do |
|---|---|---|
| `ledger_owner` | nobody (NOLOGIN) | Owns every object. Functions run with its rights (`SECURITY DEFINER`, pinned `search_path`). |
| `ledger_web` | every browser route: `/api/auth`, `/api/me`, `/api/admin` | Only token functions: user `my_*` functions (own wallet only) and admin `admin_*` functions (each checks an admin token first). It cannot name another user's wallet or touch a table. |
| `ledger_app` | trusted internal tools: demo console, traffic simulator, tests | Unscoped money and read functions (`transfer`, `get_balance`, …). |
| `ledger_admin` | the live-feed listener; operator tools | Monitor reads, freeze/unfreeze, reconciliation. It cannot move money. |
| `ledger_reporting` | optional read-only tools | Reads and reconciliation. |

**Errors** come from the database and are mapped by SQLSTATE:

| SQLSTATE | Meaning | HTTP status |
|---|---|---|
| `P1001` | Business rule broken | 422 (409 for "already in progress") |
| `P1002` | Not logged in | 401 |
| `42501` | Permission denied | 403 |
| `40P01` / `40001` | Deadlock / serialization failure | 409 |
| class `22` | Bad input | 400 |
| none | Login not configured | 503 |

---

## The logic

### Accounts

| Account | Type | Normal side | Meaning |
|---|---|---|---|
| `BANK` | asset | debit | Simulated money held at the bank |
| User wallet (one per user) | liability | credit | What the system owes that user |
| `FEE_INCOME` | income | credit | Fees earned |

The accounting equation always holds: **BANK = all wallets + FEE_INCOME**. The Admin page shows it live, with the difference (always ₹0).

### What each operation posts

| Operation | Debit | Credit | Rules |
|---|---|---|---|
| Top-up | BANK | wallet | Amount must be positive |
| Withdrawal | wallet | BANK | Refused if it would overdraw the wallet |
| Transfer | sender: amount + fee | recipient: amount; FEE_INCOME: fee | Fee is **0.5%, minimum ₹1, maximum ₹10**, rounded half up (the ₹10 cap applies from ₹2,000). No self-transfers. |
| Refund | recipient | original sender | Transfers only; partial refunds allowed; the total is capped at the original amount; the fee is not returned |

### Guarantees and what enforces them

| Guarantee | Enforced by |
|---|---|
| Every transaction balances, with at least 2 legs | Deferred constraint trigger, checked at `COMMIT` |
| No overdraft | Balance check in `post_transaction()` after locking the rows (`SELECT … FOR UPDATE`) |
| No double-spend under concurrency | Row locks: two racing payments from one wallet run one after the other |
| No deadlock between opposite transfers | Accounts are always locked in id order |
| A retry never charges twice | The idempotency key is saved in the same transaction as the payment, so a retry returns the same transaction. Reusing a key for a different request is refused. Two requests with the same key at the same instant are serialized by an advisory lock. |
| History cannot be rewritten | Triggers block `UPDATE`, `DELETE` and `TRUNCATE` on entries and transactions |
| Frozen or closed accounts cannot move money | Status checked while posting, plus a trigger on ledger entries |
| Cached balances match the ledger | `reconciliation_summary()` / `reconciliation_issues()` re-add every entry |
| Users touch only their own wallet | `ledger_web` can call only token functions, which take the wallet from the token, not the request |
| Only admins reach admin actions | Every `admin_*` function checks an admin session token; a user token is refused. Admin sign-up needs a single-use invite code. |
| Passwords and tokens are not stored readable | bcrypt (pgcrypto) for passwords; SHA-256 for session tokens and invite codes. 5 wrong passwords lock the email for 5 minutes. |

Each guarantee, with the test that proves it, is in [`docs/invariants.md`](docs/invariants.md).

### History and paging

`get_history` / `my_history` use **keyset pagination** on the index `(account_id, created_at DESC, id DESC)`. Each page continues strictly after the last `(created_at, id)`, so a deep page costs about the same as page 1. On the 120,000-entry account, a deep OFFSET page took about 225 ms, against 0.09 ms with keyset ([`docs/performance.md`](docs/performance.md)).

---

## Database files (`db/`)

Applied in order by `npm run db:apply` / `db:reset`.

| File | Contents |
|---|---|
| `01_schema.sql` | Tables `users`, `accounts`, `transactions`, `ledger_entries`; enums; constraints |
| `02_triggers.sql` | Append-only protection, deferred balance check, account status guard |
| `03_posting.sql` | `post_transaction()`: validates legs, locks accounts in id order, checks balances, posts, updates cached balances |
| `04_operations.sql` | `create_user_with_wallet`, `top_up`, `withdraw`, `transfer`, `refund`, `calculate_fee`, freeze/unfreeze |
| `05_idempotency.sql` | Idempotency key table, request fingerprint, check and record |
| `06_reads.sql` | `get_balance`, `get_history` (keyset pagination) |
| `07_reconciliation.sql` | `reconciliation_issues`, `reconciliation_summary` |
| `08_roles.sql` | Roles, ownership, `SECURITY DEFINER`, grants |
| `09_wallet_directory.sql` | `list_wallets` (admin directory) |
| `10_demo_reads.sql` | `get_transaction`, `account_overview` (demo console) |
| `11_admin_monitor.sql` | `NOTIFY` trigger, `recent_transactions`, `ledger_stats`, `transaction_refunds` |
| `12_auth.sql` | `user_credentials`, `sessions`, `ledger_web`, and the `sign_up` / `log_in` / `my_*` functions |
| `13_admin_auth.sql` | `admins`, `admin_sessions`, `admin_invites` (single-use), and the token-checked `admin_*` functions |

The schema is drawn in [`docs/er-diagram.md`](docs/er-diagram.md).

---

## Setup

**You need:**
- Node 24, or a recent Node that supports `--env-file`.
- PostgreSQL 14 or later, with the `pgcrypto` extension available. This project uses Neon.

```sh
npm install
npm run client:install
cp .env.example .env              # then set DATABASE_URL to the owner connection
npm run db:reset                  # DEVELOPMENT ONLY: drops and rebuilds the ledger schema
npm run test:db                   # every SQL test should pass
npm run server:setup-logins       # sets passwords for ledger_app, ledger_admin and ledger_web
npm run db:seed:demo              # Alice and Bob with known balances
npm run db:seed:logins            # demo user log-ins, plus a fresh single-use admin invite code
```

`server:setup-logins` writes `APP_DATABASE_URL`, `ADMIN_DATABASE_URL` and `WEB_DATABASE_URL` into `.env` and never prints a password. `.env` is git-ignored. To replace existing passwords, run `npm run server:setup-logins -- --rotate`.

To add one new `db/` file to an existing database without a reset:

```sh
node --env-file=.env scripts/apply-file.mjs db/12_auth.sql
```

---

## Running things

### The app

| Command | What it does |
|---|---|
| `npm run server` | Express server on http://localhost:3001 (set `API_PORT` to change it) |
| `npm run client:dev` | React dev server on http://localhost:5173, forwarding `/api` to port 3001 |
| `npm run client:build` | Builds `client/dist`; `npm run server` then serves the whole app on port 3001 |

The app opens on a **log-in / sign-up page** with a choice of **Wallet user** or **Admin**.

| Log-in | Email | Password |
|---|---|---|
| User | `riya.demo@mini-ledger.test` or `kabir.demo@mini-ledger.test` | `demo-password` |
| Admin | your own, created with **Admin → Sign up** and the invite code from `npm run db:seed:logins` | |

New users can sign up freely (a new wallet starts at ₹0). New admins need the single-use invite code that `npm run db:seed:logins` prints.

- **User dashboard:** balance, and **Add money / Withdraw / Transfer** (the fee is shown before you confirm). Recent activity shows refund buttons on transfers you received.
- **Admin → Dashboard:**
  - live totals with the `BANK = wallets + fees` check, and live reconciliation;
  - a **traffic simulator**: 30 simulated users sending 2–20 requests a second, some meant to fail;
  - a live transaction feed pushed by PostgreSQL, and a transaction tracer;
  - a wallet directory with freeze/unfreeze, and the full ledger check.
- **Admin → Demo console:** scripted acts played one step at a time with **Next step** (bank in/out, transfer fee, refunds, blocked payments, double-click, break the ledger, tamper), plus the concurrency demos and performance results. Each step shows the function called, the input, the output, the ledger legs and the balances.

Alice and Bob (`db:seed:demo`) are kept for `tests/09_seed.sql`, which expects their balances never to change, so use Riya and Kabir in the browser.

### Tests

| Command | What it does |
|---|---|
| `npm run test:db` | Runs every file in `tests/` in order. Each test runs in a transaction and rolls back, so nothing is left behind. Run `db:apply` or `db:reset` first. |

### Concurrency demos (terminal)

| Command | What it does |
|---|---|
| `npm run demo:setup` | Installs deliberately broken `demo.*` functions (closed to every app role) |
| `npm run demo:concurrency` | Runs the double-spend, deadlock and idempotency races 5 times each, broken version against real version, printing PASS/FAIL |
| `node --env-file=.env demos/concurrency.mjs deadlock 3` | One scenario (`double-spend`, `deadlock`, `idempotency` or `all`), a chosen number of times |
| `npm run demo:teardown` | Removes the broken functions |

### Performance evidence

| Command | What it does |
|---|---|
| `npm run db:seed:performance` | Adds about 127,000 transactions, including one very busy account |
| `npm run db:explain` | Saves `EXPLAIN ANALYZE` output to `docs/explain/`: index vs no index, OFFSET vs keyset, cached vs recomputed balance, reconciliation |
| `npm run db:check-history` | Pages through the busiest account's full history and checks that every entry appears exactly once |

The presentation walk-through, with what to say, is in [`docs/demo-script.md`](docs/demo-script.md).

---

## Project layout

| Folder | Contents |
|---|---|
| `db/` | Schema, triggers, functions and roles (the whole rule set) |
| `tests/` | SQL tests |
| `server/` | `app.js` (user routes), `admin.js` (admin routes and the admin check), `db.js` (pools and the one-function-per-request helper), `live.js` (LISTEN → SSE), `simulator.js`, `demo/` (demo console engine and scenarios) |
| `client/` | React app: `auth/` (log-in page), `wallet/` (user dashboard), `admin/` (admin dashboard), `demo/` (demo console) |
| `demos/` | Concurrency races, broken demo functions, demo seed |
| `scripts/` | Apply/reset, test runner, seeds, login setup, evidence capture |
| `docs/` | Decisions, invariants, concurrency, performance, ER diagram, demo script, viva notes |

## Documents

- [`docs/invariants.md`](docs/invariants.md): each guarantee, what enforces it, which test proves it
- [`docs/decisions.md`](docs/decisions.md): design decisions
- [`docs/concurrency.md`](docs/concurrency.md): the race and deadlock demos
- [`docs/performance.md`](docs/performance.md): indexing and pagination measurements
- [`docs/er-diagram.md`](docs/er-diagram.md): the schema
- [`docs/demo-script.md`](docs/demo-script.md): presentation walk-through
- [`docs/viva-notes.md`](docs/viva-notes.md): short answers for the viva
- [`EXTENDED-FEATURES.md`](EXTENDED-FEATURES.md): the live admin monitor and login
- [`ledger-wallet-project.md`](ledger-wallet-project.md): the original specification

## Known limitations

- Login is simulated: there is no email verification, password reset or 2FA. Tokens live in the browser tab's sessionStorage.
- The owner login or a superuser can disable triggers. Only the demo console uses the owner login, and only for fixed statements.
- History is ordered by the transaction's start time, so a slow transaction can commit behind a client's cursor.
- Refunds do not return the transfer fee (by design).
- The UPI layer (VPA, PIN, collect requests) is not included.
