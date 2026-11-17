# Design Decisions

## Phase 1: Fees and refunds

- Transfer fee: 0.5%, minimum ₹1, maximum ₹10.
- Fee rounding: round half up to the nearest paisa (e.g. 1.665 → 2, 617.285 → 617).
- The fee is non-refundable; refunds charge no new fee.
- Full and partial refunds are new transactions linked to the original transfer.

## Phase 2: Core schema

- **D1 Primary keys:** `bigint` identity. Readable, increasing IDs.
- **D2 Fixed value lists:** PostgreSQL `ENUM` types for account type, account status, transaction type and entry direction.
- **D3 Cached balance:** stored on the account's normal side. Assets: debits − credits. Liabilities and income: credits − debits.
- **D4 Currency:** column on accounts, INR only.
- **D5 System accounts:** `user_id` is NULL and a unique `code` (`BANK`, `FEE_INCOME`) is set. Exactly one of the two is present.
- **One wallet per user:** `accounts.user_id` is unique.
- **User wallets are liabilities:** enforced by a CHECK.
- **Users:** name not unique; email required and unique; deactivate with `is_active`.
- **No hard deletes:** all foreign keys use `ON DELETE RESTRICT`. Accounts are frozen or closed via `status`.
- **No overdrafts:** `allow_negative` is false for every account.
- **No `status` on transactions:** transactions commit atomically, so a saved transaction is always complete.
- **Entry timestamps:** an entry uses its transaction's timestamp.
- **Idempotency key:** nullable column on transactions for now (Phase 6).
- **Metadata:** `jsonb`.
- **Constraint names:** CHECK constraints are named explicitly. UNIQUE constraints use PostgreSQL's default `<table>_<column>_key` names.

## Phase 3: Invariant triggers

- **D6 Balance check:** Option C. Deferred constraint triggers on both `transactions` and `ledger_entries` share one check function. This rejects empty transactions and catches later entries added to an existing transaction.
- **Balance lookup index:** Index `ledger_entries(transaction_id)` so each balance check can find one transaction's entries without scanning the full ledger.
- **D7 Account status:** Block postings in both directions for frozen or closed accounts. Account status is the only switch; user deactivation will freeze or close the user's account.
- **D8 Append-only tables:** Both `ledger_entries` and `transactions` are append-only. Reject `UPDATE`, `DELETE`, and `TRUNCATE`; correct mistakes with a reversing transaction.
- **Trigger rule error code:** Use SQLSTATE `P1001` for trigger-enforced business-rule violations (append-only, balance, and account-status checks). The API can recognize this code as a rule violation.

## Phase 4: Posting function

- **D9 Legs input:** Pass the legs to `post_transaction()` as a JSONB function parameter: an array of objects containing `account_id`, `direction`, and `amount`. This JSONB is temporary input, not a table column. The function writes each leg as a separate `ledger_entries` row. This is separate from `transactions.metadata`, which is optional JSONB stored on the transaction.

- **D10 Cached balance:** Updated inside `post_transaction()` itself, not by a trigger. Only this function inserts into `ledger_entries`, and reconciliation (Phase 8) checks the cache.
- **D11 Locking and repeated accounts:** The function locks every affected account with `FOR UPDATE` in ascending id order before reading any balance. If an account appears in several legs, its legs are combined into one net change per account, applied once, and the overdraft check uses that net result. (Example: the fee account.)
- **Self-transfers:** `post_transaction()` does not reject a debit and credit on the same account (they net to zero). `transfer()` rejects sender = recipient in Phase 5.
- **D12 Overdraft check:** Done inside `post_transaction()` after the account locks are taken, on accounts where `allow_negative` is false.
- **D13 Broken demo versions:** The unsafe double-spend and deadlock functions live in a separate `demo` schema. Production code never calls anything in `demo`, so the real function has no "unsafe" switch.
- **Return value:** `post_transaction()` returns the new transaction id (`BIGINT`).
- **Input validation:** At least two legs; `account_id` and `amount` must be whole numbers, `amount` > 0; `direction` is `debit` or `credit`; legs must balance (the deferred trigger remains as a backstop). All rule violations use SQLSTATE `P1001`.
