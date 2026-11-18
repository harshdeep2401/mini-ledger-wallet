# Invariants

Each guarantee the database enforces, what enforces it, and how it is tested.
(Started in Phase 3. Later phases add rows.)

| # | Invariant | Enforced by | Tested in |
|---|---|---|---|
| 1 | Entry amounts are positive | `CHECK (amount > 0)` on `ledger_entries` | Phase 2 schema checks (planned) |
| 2 | A user wallet is a liability, and an account is either a user wallet or a system account | CHECK constraints on `accounts` | Phase 2 schema checks (planned) |
| 3 | Every transaction has at least one entry and its debits equal its credits | `balance_check()` via deferred constraint triggers on `ledger_entries` and `transactions` (checked at COMMIT) | `tests/02_triggers.sql`: balanced commit, unbalanced, empty, extra leg |
| 4 | Ledger history is append-only (no UPDATE, DELETE or TRUNCATE) | `prevent_changes()` via triggers on `ledger_entries` and `transactions` | `tests/02_triggers.sql`: update, delete, truncate on both tables |
| 5 | No postings to frozen or closed accounts (debits and credits) | `status_guard()` via BEFORE INSERT trigger on `ledger_entries` | `tests/02_triggers.sql`: frozen and closed |
| 6 | Every posting locks its accounts in id order, rejects overdrafts after the lock, and keeps cached balances equal to the ledger | `post_transaction()` | `tests/03_posting.sql`: overdraft, repeated accounts, frozen, reconciliation |
| 7 | A user and their liability wallet are created together | `create_user_with_wallet()` (one transaction) | `tests/04_operations.sql`: linked wallet, duplicate email |
| 8 | Fee is 0.5%, rounded half up, min 100 paise, max 1,000 paise | `calculate_fee()` | `tests/04_operations.sql`: boundary and rounding values |
| 9 | Transfers are between two different user wallets only; sender pays amount + fee | `transfer()` | `tests/04_operations.sql`: self-transfer, system accounts, fee on top |
| 10 | Refunds apply only to transfers, never return the fee, and total refunds cannot exceed the recipient amount, even concurrently | `refund()` (locks the original transaction row before reading the total) | `tests/04_operations.sql`: full, partial, over-cap, refund of refund/top-up, spent funds. The concurrent case is tested in Phase 11. |
| 11 | Only an active user wallet can be frozen and only a frozen one unfrozen; system accounts never | `freeze_account()`, `unfreeze_account()` | `tests/04_operations.sql`: transitions and illegal changes |

Trigger-enforced rule violations raise SQLSTATE `P1001`, so the API can tell them apart from crashes.

## Known limitations

- **Triggers can be disabled by the table owner or a superuser.** On Neon, the default login role owns the tables, so triggers alone don't make the ledger tamper-proof against that role. Phase 9 adds a separate app role that owns nothing and can only call the database functions.
- **Rejecting a refund to a frozen account is deliberate (D7).** Postings are blocked in both directions until the account is unfrozen.
