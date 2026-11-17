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
