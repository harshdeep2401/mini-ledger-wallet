# Double-Entry Ledger / Wallet System — DBMS Project

## Overview

A mini payments backend. Users hold wallets and can top up, transfer to each other, withdraw and receive refunds. The central rule is that **money is never just a number you update**: a balance is the sum of immutable ledger entries, and the database itself refuses to record anything that doesn't balance.

This is a simulation. No real money or payment gateway is involved, and the README says so clearly.

## Division of work

- **Database layer (written by hand):** schema, constraints, triggers, PL/pgSQL functions, indexing, concurrency demos. This is the graded core of the project.
- **API server (AI-assisted):** a thin wrapper around the database functions.
- **Frontend (AI-assisted):** a light UI to keep the demo presentable.

The rule that holds the design together: **the API never touches a balance.** Every endpoint calls exactly one database function and returns its result. No balance checks, fee calculations or ledger logic live in application code, so every guarantee is enforced by the database.

## Core concepts

**Double-entry bookkeeping.** Every transaction has two or more entries, and total debits must equal total credits. Accounts have types (asset, liability, income, expense). User wallets are *liabilities* of the platform, because it owes users that money: a debit decreases a wallet and a credit increases it.

Worked example — Alice sends Bob ₹500 and pays a ₹5 fee:

| Account | Debit | Credit |
|---|---|---|
| Alice's wallet | 505 | |
| Bob's wallet | | 500 |
| Fee income (system account) | | 5 |
| **Total** | **505** | **505** |

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
| `accounts` | User wallets and seeded system accounts (bank, fee income): type, currency, status (active/frozen/closed), cached balance, whether negative balance is allowed |
| `transactions` | One row per business event: type, status, idempotency key, `reverses_transaction_id`, metadata |
| `ledger_entries` | The heart of the system: transaction, account, direction (debit/credit), amount (> 0), timestamp |
| `idempotency_keys` | Key, request hash, stored response, state |

## Features

**Operations** (each a PL/pgSQL function):
- Create user and wallet
- Top-up (bank → wallet)
- P2P transfer with fee (three-leg transaction)
- Withdrawal (wallet → bank)
- Full or partial refund as a reversing transaction, capped so total refunded can't exceed the original
- Freeze / unfreeze an account

**Reads:**
- Current balance
- Transaction history with keyset pagination

**Idempotency:**
- Same key + same payload → returns the stored response
- Same key + different payload → rejected
- Key still in flight → conflict response

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

## Concurrency and performance

**Break-then-fix demos** (triggered with a Python script using threads, or pgbench):
1. **Double-spend:** two ₹800 withdrawals against a ₹1000 wallet both succeed without locking. Fixed with `SELECT ... FOR UPDATE` on the account row.
2. **Deadlock:** a transfer A→B racing with B→A deadlocks. Fixed by always locking accounts in ascending id order.

**Performance:**
- Seed ~1M ledger entries using `generate_series`
- Show the history query before and after an index on `(account_id, created_at, id)` with `EXPLAIN ANALYZE`
- Compare `OFFSET` pagination with keyset pagination on deep pages

**Bonus if time allows:** a quick throughput comparison of pessimistic locking vs. `SERIALIZABLE` isolation with retry.

## API and frontend

**API endpoints** (each wraps one DB function): create user/wallet, top-up, transfer, withdraw, refund, freeze, get balance, get history, run reconciliation.

**Frontend screens:** wallet list, balance and history view, transfer form, and a "Check ledger" button that runs reconciliation and shows the result.

**Checks for AI-generated code:**
- No business logic outside the database
- Each request runs in its own transaction; no connections held open across requests
- The frontend generates one idempotency key per user action, so a double-click demonstrates the idempotency protection
- Be able to explain every part of the API and frontend in a viva

## Out of scope

Holds (authorize/capture/void), merchant settlements, outbox/webhooks, multi-currency and FX, partitioning, spending limits, monthly statements, point-in-time balance, disputes, crash testing.

## Build plan (3 days)

| Day | Work |
|---|---|
| 1 | Debit/credit pattern for each transaction type on paper. Schema, constraints and triggers (deferred trigger first, since it's the riskiest). ER diagram and normalization notes. |
| 2 | Posting function and operation functions, idempotency, reconciliation, seed data, indexing and `EXPLAIN ANALYZE`. Generate the API and frontend against the finished function signatures. |
| 3 | Concurrency demos, end-to-end testing through the UI, report and demo script. |

## Deliverables

- ER diagram with normalization notes
- An "invariants" document listing each guarantee and how the database enforces it
- `EXPLAIN ANALYZE` before/after results for indexing and pagination
- Concurrency write-up showing each break-then-fix scenario
- Demo script and a short README (including the simulation disclaimer)
