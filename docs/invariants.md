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

Trigger-enforced rule violations raise SQLSTATE `P1001`, so the API can tell them apart from crashes.

## Known limitations

- **Triggers can be disabled by the table owner or a superuser.** On Neon, the default login role owns the tables, so triggers alone don't make the ledger tamper-proof against that role. Phase 9 adds a separate app role that owns nothing and can only call the database functions.
- **Rejecting a refund to a frozen account is deliberate (D7).** Postings are blocked in both directions until the account is unfrozen.
