# Double-Entry Ledger / Wallet System — DBMS Project

## Overview

A mini payments backend. Users hold wallets and can top up, transfer to each other, withdraw and receive refunds. The central rule is that **money is never just a number you update**: a balance is the sum of immutable ledger entries, and the database itself refuses to record anything that doesn't balance.

This is a simulation. No real money or payment gateway is involved, and the README says so clearly.

**UPI-style layer.** The project is presented as a *UPI-style payment simulator*. People pay each other by a virtual payment address (VPA such as `alice@minibank`), authorise with a PIN, receive a payment reference number, and can raise "collect" requests that the payer approves or declines. This is a thin product layer on top of the ledger: the double-entry core (entries, balance trigger, idempotency, locking, reconciliation) is unchanged. It mimics UPI's user experience and flows only; it does **not** connect to NPCI, any bank, or the real UPI network, and the README must say so.

## Division of work

- **Database layer (written by hand):** schema, constraints, triggers, PL/pgSQL functions, indexing, concurrency demos. This is the graded core of the project.
- **API server (AI-assisted):** a thin wrapper around the database functions.
- **Frontend (AI-assisted):** a light UI to keep the demo presentable.

The rule that holds the design together: **the API never touches a balance.** Every endpoint calls exactly one database function and returns its result. No balance checks, fee calculations or ledger logic live in application code, so every guarantee is enforced by the database.

## Core concepts

**Double-entry bookkeeping.** Every transaction has two or more entries, and total debits must equal total credits. Accounts have types (asset, liability, income, expense). User wallets are *liabilities* of the platform, because it owes users that money: a debit decreases a wallet and a credit increases it.

Worked example — Alice sends Bob ₹500 and pays a ₹2.50 fee (0.5% of the amount, minimum ₹1, maximum ₹10, rounded half up to the paisa):

| Account | Debit | Credit |
|---|---|---|
| Alice's wallet | 502.50 | |
| Bob's wallet | | 500 |
| Fee income (system account) | | 2.50 |
| **Total** | **502.50** | **502.50** |

A ₹1000 top-up debits the platform's bank account (an asset) and credits Alice's wallet. Money never appears from nowhere; it always comes from some account, including system accounts.

**Core rules:**
- Entries are append-only. Mistakes are fixed with a reversing transaction, never an `UPDATE` or `DELETE`.
- Amounts are integers in minor units (paise), never floats.
- Each transaction commits atomically, or not at all.
- Retried requests never charge twice (idempotency).
- Balance is derived from entries. The cached balance column exists only for speed and is verified by reconciliation.

## Architecture

```
Frontend (light UI)  →  API server (thin wrapper)  →  PostgreSQL
                                                     ├─ tables + constraints
                                                     ├─ triggers (invariants)
                                                     └─ PL/pgSQL functions (all business logic)
```

## Schema (in scope)

| Table | Purpose |
|---|---|
| `users` | Customers |
| `accounts` | User wallets and seeded system accounts (bank, fee income): type, currency, status (active/frozen/closed), cached balance, whether negative balance is allowed, hashed UPI PIN, failed-PIN counter / lock state, daily send limit |
| `transactions` | One row per business event (append-only, no status column): type, idempotency key, `reverses_transaction_id`, metadata, unique payment reference (RRN) |
| `ledger_entries` | The heart of the system: transaction, account, direction (debit/credit), amount (> 0), timestamp |
| `idempotency_keys` | Key, request fingerprint (SHA-256), transaction id; written in the same transaction as the money movement, append-only |
| `vpas` | Virtual payment addresses (`name@minibank`) mapped to an account; unique, one account can have several |
| `payment_requests` | Collect requests: payee, payer VPA, amount, status (pending / approved / declined / expired), expiry time, resulting transaction |

## Features

**Operations** (each a PL/pgSQL function):
- Create user and wallet
- Top-up (bank → wallet)
- P2P transfer with fee (three-leg transaction)
- Withdrawal (wallet → bank)
- Full or partial refund as a reversing transaction, capped so total refunded can't exceed the original
- Freeze / unfreeze an account
- Register a VPA for a wallet
- Set / change the UPI PIN (stored hashed, never plain text)
- Pay by VPA: resolve VPA → verify PIN → check daily limit → transfer. A successful payment returns a payment reference (RRN).
- Collect request: payee raises a request against a payer's VPA; the payer approves (with PIN), declines, or lets it expire. Approval posts a normal transfer.

**Reads:**
- Current balance
- Transaction history with keyset pagination
- Resolve a VPA to the payee's display name (so the user confirms who they're paying before entering a PIN)
- List pending collect requests for a VPA

**Idempotency:**
- Same key + same payload → returns the stored response
- Same key + different payload → rejected
- Key still in flight → the second request fails immediately with an "already in progress" error (it does not wait)
- A missing key is rejected; a failed request stores no key, so the same key can be retried

**Reconciliation check** (a SQL view or function):
- Global total debits = total credits
- Every cached balance = sum of that account's entries

## Database-enforced guarantees

- `CHECK (amount > 0)` on ledger entries
- **Deferred constraint trigger** verifying debits = credits per transaction at commit time
- Trigger raising an error on any `UPDATE` or `DELETE` of `ledger_entries`, backed by revoking those privileges from the app role
- Postings to frozen or closed accounts are blocked
- No overdrafts on accounts that don't allow negative balances
- Unique constraint on the idempotency key
- Separate DB roles: app, read-only reporting, admin
- PIN is stored hashed (pgcrypto); verified inside the payment function, never in the API
- Too many wrong PIN attempts locks the account's payments (counter lives in the DB)
- Daily send limit enforced in the payment function
- A collect request can only move `pending → approved/declined/expired`; an approved or expired request can't be paid again
- Unique VPA and unique payment reference (RRN)

## Concurrency and performance

**Break-then-fix demos** (triggered with a Python script using threads, or pgbench):
1. **Double-spend:** two ₹800 withdrawals against a ₹1000 wallet both succeed without locking. Fixed with `SELECT ... FOR UPDATE` on the account row.
2. **Deadlock:** a transfer A→B racing with B→A deadlocks. Fixed by always locking accounts in ascending id order.
3. **Failed payment with auto-reversal (UPI-flavoured, stretch goal):** a payment is posted in two steps (payer → a system "in-transit" account, then in-transit → payee). A simulated failure or timeout hits between the steps; the system detects the stuck payment and posts a reversing transaction so the payer is made whole and the ledger still balances. The two-step design and the in-transit account are your design decision; keep it to one reversal function plus a script that injects the failure.

**Performance:**
- Seed ~1M ledger entries using `generate_series`
- Show the history query before and after an index on `(account_id, created_at, id)` with `EXPLAIN ANALYZE`
- Compare `OFFSET` pagination with keyset pagination on deep pages

**Bonus if time allows:** a quick throughput comparison of pessimistic locking vs. `SERIALIZABLE` isolation with retry.

**Stretch (only if everything else is done): multiple simulated banks.** Two or three fake banks (e.g. `minibank`, `fakebank`), each with its own settlement account. A cross-bank payment debits the payer's bank and credits the payee's bank, and a net settlement job zeroes the balances between banks. This is the largest possible addition to the schema and to reconciliation, so treat it as optional.

## API and frontend

**API endpoints** (each wraps one DB function): create user/wallet, top-up, transfer, withdraw, refund, freeze, get balance, get history, run reconciliation, register VPA, set PIN, resolve VPA, pay by VPA, create / approve / decline collect request, list pending requests.

**Frontend screens:** wallet list, balance and history view, a UPI-style pay flow (enter or pick a VPA → confirm payee name and amount → PIN pad → success / failure screen with the payment reference), a collect-requests inbox (approve / decline), and a "Check ledger" button that runs reconciliation and shows the result.

**Checks for AI-generated code:**
- No business logic outside the database
- Each request runs in its own transaction; no connections held open across requests
- The frontend generates one idempotency key per user action, so a double-click demonstrates the idempotency protection
- Be able to explain every part of the API and frontend in a viva

## Out of scope

Holds (authorize/capture/void), merchant settlements, outbox/webhooks, multi-currency and FX, partitioning, monthly statements, point-in-time balance, disputes, crash testing, any real integration with NPCI / UPI / banks, real QR scanning (a mock QR screen is fine), and the UPI-Lite / mandate / autopay features.

*Moved into scope by the UPI-style framing:* a simple daily send limit and the `pending` state for collect requests (not full authorize/capture holds).

**Open decisions (yours):** whether P2P payments by VPA carry the standard 0.5% fee or are free like real UPI; the daily limit amount; whether to attempt the failed-payment auto-reversal and the multi-bank stretch.

## Build plan (3 days)

| Day | Work |
|---|---|
| 1 | Debit/credit pattern for each transaction type on paper. Schema (including `vpas`, PIN and limit columns, `payment_requests`), constraints and triggers (deferred trigger first, since it's the riskiest). ER diagram and normalization notes. |
| 2 | Posting function and operation functions, idempotency, reconciliation, UPI layer functions (VPA, PIN check, daily limit, pay by VPA, collect requests), seed data, indexing and `EXPLAIN ANALYZE`. Generate the API and frontend against the finished function signatures. |
| 3 | Concurrency demos (plus the failed-payment demo if attempted), end-to-end testing through the UPI-style UI, report and demo script. The UPI layer adds roughly half a day of SQL, so cut the stretch goals first if time runs short. |

## Deliverables

- ER diagram with normalization notes
- An "invariants" document listing each guarantee and how the database enforces it
- `EXPLAIN ANALYZE` before/after results for indexing and pagination
- Concurrency write-up showing each break-then-fix scenario
- Demo script and a short README (including the simulation disclaimer: UPI-style only, no connection to NPCI, banks or real money)
