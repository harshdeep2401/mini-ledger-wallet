# Invariants

Each guarantee the database enforces, what enforces it, and how it is tested.
(Started in Phase 3. Later phases add rows.)

| # | Invariant | Enforced by | Tested in |
|---|---|---|---|
| 1 | Entry amounts are positive | `CHECK (amount > 0)` on `ledger_entries` | Phase 2 schema checks (planned) |
| 2 | A user wallet is a liability, and an account is either a user wallet or a system account | CHECK constraints on `accounts` | Phase 2 schema checks (planned) |
| 3 | Every transaction has at least one entry and its debits equal its credits | `balance_check()` via deferred constraint triggers on `ledger_entries` and `transactions` (checked at COMMIT); independently audited by reconciliation | `tests/02_triggers.sql`: balanced commit, unbalanced, empty, extra leg; `tests/07_reconciliation.sql`: global and per-transaction totals |
| 4 | Ledger history is append-only (no UPDATE, DELETE or TRUNCATE) | `prevent_changes()` via triggers on `ledger_entries` and `transactions` | `tests/02_triggers.sql`: update, delete, truncate on both tables |
| 5 | No postings to frozen or closed accounts (debits and credits) | `status_guard()` via BEFORE INSERT trigger on `ledger_entries` | `tests/02_triggers.sql`: frozen and closed |
| 6 | Every posting locks its accounts in id order, rejects overdrafts after the lock, and keeps cached balances equal to the ledger | `post_transaction()`; `reconciliation_issues()` independently recomputes balances from entries | `tests/03_posting.sql`: overdraft, repeated accounts; `tests/07_reconciliation.sql`: cached balances, negative balances, and corruption detection |
| 7 | A user and their liability wallet are created together | `create_user_with_wallet()` (one transaction) | `tests/04_operations.sql`: linked wallet, duplicate email |
| 8 | Fee is 0.5%, rounded half up, min 100 paise, max 1,000 paise | `calculate_fee()` | `tests/04_operations.sql`: boundary and rounding values |
| 9 | Transfers are between two different user wallets only; sender pays amount + fee | `transfer()` | `tests/04_operations.sql`: self-transfer, system accounts, fee on top |
| 10 | Refunds apply only to transfers, never return the fee, and total refunds cannot exceed the recipient amount, even concurrently | `refund()` (locks the original transaction row before reading the total) | `tests/04_operations.sql`: full, partial, over-cap, refund of refund/top-up, spent funds. The concurrent case is tested in Phase 11. |
| 11 | Only an active user wallet can be frozen and only a frozen one unfrozen; system accounts never | `freeze_account()`, `unfreeze_account()` | `tests/04_operations.sql`: transitions and illegal changes |
| 12 | A retried request never posts twice: the same key and request return the saved transaction id; the same key with a different request is rejected; a missing key is rejected; a failed request stores no key | `idempotency_fingerprint()`, `check_idempotency()`, `record_idempotency()` and the key table (written in the same transaction as the money movement); advisory lock on the key | `tests/05_idempotency.sql`: replay, different amount/operation, missing/empty/long key, failed-then-retried, replay after balance drop, replay on frozen wallet. The concurrent case is tested in Phase 11. |
| 13 | Idempotency key records are permanent and append-only | `prevent_changes()` triggers on `idempotency_keys` | `tests/02_triggers.sql`: truncate is blocked (also reached through the foreign key) |
| 14 | History pages return every entry exactly once, newest first, and `get_balance` agrees with the signed history | `get_history()` (keyset cursor `(created_at, id)`, index on `(account_id, created_at DESC, id DESC)`), `get_balance()` | `tests/06_reads.sql`: page walk, same-timestamp entries, posting between pages, limits, balance vs history sum |
| 15 | The ledger can be re-verified from scratch: global debits = credits, every transaction balances, every cached balance equals the balance recomputed from entries, no forbidden negative balance, idempotency keys match their transactions, refund totals stay within the transfer amount | `reconciliation_issues()` (one read-only statement, one snapshot, no locks, independent of the posting code) and `reconciliation_summary()` | `tests/07_reconciliation.sql`: healthy cases, empty wallet, one and two corrupted balances, one-paisa error, and deliberate corruption of each other check (rolled back) |
| 15 | Global and per-transaction debits equal credits; account balances, overdrafts, idempotency records, and refund caps reconcile with ledger entries | `reconciliation_issues()` plus `reconciliation_summary()` | `tests/07_reconciliation.sql`: clean ledger, empty account, operation mix, over-cap refund, negative balance, idempotency mismatch, balance corruption, global imbalance, and recovery |

Trigger-enforced rule violations raise SQLSTATE `P1001`, so the API can tell them apart from crashes.

## Known limitations

- **Triggers can be disabled by the table owner or a superuser.** On Neon, the default login role owns the tables, so triggers alone don't make the ledger tamper-proof against that role. Phase 9 adds a separate app role that owns nothing and can only call the database functions.
- **Rejecting a refund to a frozen account is deliberate (D7).** Postings are blocked in both directions until the account is unfrozen.
- **History order follows `created_at`, which is the transaction's start time, not its commit time.** A slow transaction that started earlier can commit after a client has already read past its position, so that row can appear behind the client's cursor. Entries within one transaction are ordered by `id`. Accepted for a simulator.
- **The history tests cannot vary `created_at`.** Each test runs in one transaction, so all its entries share a timestamp and paging is decided by `id` alone. The `created_at` half of the cursor needs data from separate transactions (Phase 10 seed data).
- **`signed_change` in `get_history()` repeats the account-type sign rule used by `post_transaction()`.** They must be kept in sync.
- **The concurrent same-key case ("already in progress") needs two sessions,** so it is tested in Phase 11, not in `tests/05_idempotency.sql`.
- **Reconciliation proves the state, it does not prevent damage.** It reports a corrupted balance or an imbalance after the fact. Prevention is the triggers and (from Phase 9) the roles.
- **The reconciliation test about a fresh database only passes right after `db:reset`** (it expects exactly the two system accounts and no transactions).
