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

## Phase 5: Operation functions

- **D14 Fee:** Computed by a separate `calculate_fee(amount)` function with the policy as constants inside it (0.5%, minimum 100 paise, maximum 1,000 paise, round half up using `NUMERIC`, never floats). No settings table: one less table and failure mode. The sender pays amount + fee on top; the recipient receives the full amount.
- **D15 Refunds:** Only `transfer` transactions can be refunded (not top-ups, withdrawals or refunds). A refund reverses only the recipient's amount leg, never the fee. Total refunded per transfer cannot exceed what the recipient received. `refund()` locks the original transaction row (`FOR UPDATE`) before reading the refunded-so-far total, so two concurrent refunds cannot both pass the cap. If the recipient has spent the money, the refund fails with the normal insufficient-funds error.
- **D16 Return values:** Money movers (`top_up`, `withdraw`, `transfer`, `refund`) return the new transaction id as `BIGINT`. `create_user_with_wallet` returns the user id; `freeze_account` and `unfreeze_account` return the account id. Chosen over `jsonb` for simplicity; any extra detail (fee, balances) is read separately.
- **System accounts:** `BANK` (asset) and `FEE_INCOME` (income) are looked up by `code`. A missing one raises a clear `P1001` error. They are created by an idempotent insert in `db/04_operations.sql`, so every `db:reset` has them.
- **Transfer rules:** Both ends must be user wallets (never system accounts) and must differ.
- **Freeze rules:** Only `active → frozen` and `frozen → active` are legal. System accounts and closed accounts cannot be frozen or unfrozen through these functions.
- **Duplicate email:** `create_user_with_wallet` catches the unique violation and raises `P1001`. Emails are trimmed and lower-cased before saving.
- **Idempotency key:** Every money mover already accepts an optional `p_idempotency_key` and passes it to `post_transaction()`; Phase 6 adds the key table and replay logic.

- **Idempotency key (superseded):** the key was optional in Phase 5; Phase 6 now requires it on every money mover (see below).

## Phase 6: Idempotency

- **Missing key:** a money mover called without a key is rejected with `P1001`. Empty or over-200-character keys are also rejected.
- **Same key, same request:** returns the saved transaction id; nothing is posted again.
- **Same key, different amount or different operation:** rejected with `P1001`.
- **Failed first attempt:** leaves no key. A retry with the same key runs as a new request.
- **Replay after the wallet was frozen:** the frozen-account error wins over the saved result.
- **Concurrent requests with the same key:** the second fails fast ("already in progress") using a transaction-scoped advisory lock.
- **D17 Fingerprint:** operation name plus the arguments that change the outcome, nothing else (the key itself is excluded). Built as `jsonb` so key order is stable, hashed with `sha256`.
- **D18 Design:** same-transaction (design A). The key row is saved in the same database transaction as the money movement, so they commit or roll back together.
- **D19 Failures:** failed requests store nothing.
