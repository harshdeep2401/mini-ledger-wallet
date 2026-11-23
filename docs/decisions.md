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

## Phase 7: Read functions

- **Balance source:** `get_balance` returns `cached_balance`, because it is a single-row read. Phase 8 reconciliation proves it matches the entries.
- **Paging method:** keyset pagination. The last row the caller saw is the cursor, and an index finds the next rows directly. `OFFSET` is slow because PostgreSQL still reads and discards every skipped row.
- **D20 Cursor:** `(created_at, id)`, newest first. `created_at` alone is not enough because all entries of one transaction share it; `id` breaks the tie. "After the cursor" is one row comparison on the pair, not two separate column comparisons.
- **History index:** `created_at` comes first in the index, then `id`.
- **D21 History rows:** the columns suggested in tutorial 06. The other party is the other user wallet in the transaction, otherwise a system account such as `BANK`.
- **Missing account:** `get_balance` and `get_history` raise `P1001`.
- **Page size:** default 20, maximum 100. Anything outside 1–100 is rejected with `P1001`, and so is a cursor with only one of its two values.
- **Last page:** fetch one extra row to tell whether another page exists.

## Phase 8: Reconciliation

- **Checks in scope:** (A) global debits = global credits; (B) each account's `cached_balance` = balance recomputed from its entries. Optional checks included: every transaction balances on its own; no account with `allow_negative = false` is negative; every `idempotency_keys` row points at a transaction with the same key; every refund total is within its original transfer's recipient amount.
- **D22 Output shape:** both. A detail function returns one row per problem (check name, account or transaction id, expected, actual, difference), and a thin summary on top gives the pass/fail boolean for the "Check ledger" button.
- **Independent recomputation:** balances are recomputed from entries by the check's own sign rule, not by reusing `post_transaction()` code, so a bug in posting cannot hide itself.
- **Accounts with no entries:** recomputed as 0 and still checked.
- **Snapshot and locks:** the check reads one consistent snapshot and takes no locks, so it never blocks payments.

## Phase 9: Roles and privileges

- **Roles:** an owner role that owns the schema, tables and functions, plus `ledger_app`, `ledger_reporting` and `ledger_admin`. Nobody uses the owner day to day.
- **D23 App role:** can only `EXECUTE` the public API functions: the money movers, `create_user_with_wallet`, `get_balance`, `get_history` and `calculate_fee`. `calculate_fee` is pure and the UI can use it to preview the fee. It has no access to any table (no `SELECT`, `INSERT`, `UPDATE`, `DELETE` or `TRUNCATE`) and is not the owner, so it cannot disable triggers.
- **Internal helpers are closed:** `post_transaction`, `check_idempotency`, `record_idempotency`, `idempotency_fingerprint`, `assert_transaction_accounts_active` and the trigger functions cannot be called by the app role. Calling `post_transaction` directly would skip the rules in `transfer()` (fee, self-transfer, account kinds).
- **Freeze and unfreeze:** admin only, not the app role.
- **`SECURITY DEFINER`:** the public functions run with the owner's rights so the app needs no table access. Every one pins `search_path`, with `pg_catalog` first, and all names inside are schema-qualified. Trigger functions and other functions that need no extra rights stay `SECURITY INVOKER`.
- **`PUBLIC` access:** the default `EXECUTE` for `PUBLIC` is revoked on existing and future functions, and `PUBLIC` gets no access to the schema. Each role gets schema `USAGE` and `EXECUTE` on exactly its list, and a new function is closed until it is granted.
- **D24 Reporting role:** no table access; it can call the read functions, `reconciliation_issues()` and `reconciliation_summary()`, which run as the owner. It cannot call any money-moving function. Sensitive columns such as the planned PIN hash are never visible to it.
- **Admin role:** day-to-day maintenance without being the owner: freeze and unfreeze accounts and run reconciliation.
- **`demo` schema:** the deliberately broken functions (D13) are not callable by the app role.
- **Re-running:** `db/08_roles.sql` creates roles only if they do not exist, because `db:reset` drops the schema but not cluster-wide roles.
- **Passwords:** never committed to git; login credentials for app, reporting and admin roles are set out of band and kept in `.env`.
- **Login roles:** `ledger_owner` is `NOLOGIN`; `ledger_app`, `ledger_reporting` and `ledger_admin` are separate `LOGIN` roles. Their passwords are set out of band and kept only in `.env`.
- **Testing roles:** tests become a role with `SET LOCAL ROLE`, expect "permission denied" (a different error class from `P1001`), and always include a positive test that the allowed calls really work.
- **Role attributes:** only `LOGIN`/`NOLOGIN`, `NOCREATEDB` and `NOCREATEROLE` are set explicitly. Neon refuses `NOSUPERUSER`, `NOREPLICATION` and `NOBYPASSRLS` for a non-superuser, and `CREATE ROLE` leaves them off by default.
- **Functions in later files:** created after `SET ROLE ledger_owner`, so the closed-by-default privileges apply.

## Phase 10: Seed data and performance

- **Seed placement:** the seed stays separate from the numbered `db/` files, so `db:reset` and `db:apply` leave the ledger empty. This keeps `tests/07_reconciliation.sql`'s "fresh database" check valid. The seed is run as its own deliberate step.
- **D25 Big seed:** way 1, fully honest. The load goes through the operation functions in batches, one database transaction per batch, so every rule, lock, idempotency check and cached-balance update is exercised. No direct inserts into the ledger tables and no disabled triggers.
- **Reconciliation proves the seed:** `reconciliation_summary()` must report healthy after the demo seed and after the big load.
- **Demo seed:** built only from operation functions, each call with an idempotency key. Alice starts at a known balance so the demo arithmetic is easy (₹500 transfer, ₹2.50 fee).
- **Realistic data:** `FEE_INCOME` is hot because each transfer credits its fee; `BANK` appears in top-ups and withdrawals because transfers do not touch it. The workload is mostly transfers with some top-ups and withdrawals, and no wallet goes negative.
- **Timestamps:** because the load goes through the functions, `created_at` is real time, so entries of different batches differ by seconds rather than months. Accepted; the cursor's `created_at` half is exercised by that spread, not by synthetic dates.
- **Size:** chosen to fit Neon's storage and compute limits, a few hundred thousand entries if 1M does not fit. The actual number is recorded in `docs/performance.md`.
- **Performance seed target:** 1,000 wallets, 1,000 top-ups, 120,000 transfers and 6,000 withdrawals (127,000 transactions; 374,000 entries). Every wallet receives ₹10,000 first; generated outgoing transfers including fees and withdrawals stay below that amount. Stable emails and idempotency keys make reruns resume-safe.
- **Measurements:** history query with and without the `(account_id, created_at, id)` index; `OFFSET` against keyset on a deep page; keyset page 1 against a deep page; reconciliation time on the full data; `get_balance` against summing a hot account's entries.
- **How to measure:** `ANALYZE` after the load; `EXPLAIN (ANALYZE, BUFFERS)`; repeat each query and report the steady (warm) timing; benchmark the underlying query with literal values, since the function hides its plan; always restore the index afterwards.
- **Evidence:** raw plans saved in `docs/explain/`, summarised in `docs/performance.md` with the query, timings and one sentence of interpretation each.
- **Reported numbers:** three runs per query; report the steady runs 2–3 (run 1 is cold). Even with the index, `OFFSET 100000` stays slow, so keyset is the supported paging method (measured: 225 ms vs 0.09 ms).
- **Not a test file:** the history walk (`db:check-history`) is a one-off script because it needs the large dataset; recorded as a limitation in `docs/invariants.md`.

## Phase 11: Concurrency demos

- **Demo placement:** the broken functions are installed by `npm run demo:setup` from `demos/sql/`, not by `db:reset`/`db:apply`. They are owner-only; `tests/10_demo_closed.sql` checks that no app role can use them.
- **Reproducible races:** the unsafe functions pause one second between their check and their write, so the race happens every time.
- **Demos:** double-spend, deadlock and idempotency race. The `FOR UPDATE` vs `SERIALIZABLE` bonus is skipped.
- **Cleanup:** the unsafe double-spend leaves a negative wallet; it is repaired with a normal top-up (append-only history), then reconciliation is checked.
- **Evidence:** five consecutive runs saved in `docs/concurrency-output.txt`; write-up in `docs/concurrency.md`.


## Phase 12: API and demo console

- **Stack:** Express in `server/`, React (Vite) in `client/`. API first, then UI.
- **Scope:** existing functions only; no UPI layer (VPA, PIN, collect requests).
- **Demo Console:** a separate guided tab (acts from `PROJECT-TOUR.md`) with an "Under the hood" panel; Wallets/Pay stay as the plain app.
- **Attack and tamper demos:** run by the server on the owner login (`DATABASE_URL`, used only inside `server/demo/`), fixed statements only, always rolled back. Tamper/repair are the only persistent changes; leaving a scenario repairs the tamper.
- **Scenarios:** scripted, one step per "Next step" click; each step states whether it should be accepted or refused and the screen shows what the database did (ledger legs, balances before/after, whole-ledger check, functions called and timing). Fresh wallets per run so numbers repeat.
- **Acts built:** money in/out, transfer fee, refunds, overdraft/frozen, double-click idempotency, try-to-break-it, reconciliation tamper, concurrency (streamed from `demos/concurrency.mjs`), performance (saved numbers).
- **New DB reads:** `db/10_demo_reads.sql` adds `get_transaction` (ledger legs) and `account_overview` (balances plus BANK and FEE_INCOME), read-only, granted to the app roles.
- **Whole-ledger check:** about 1.2 s on the big ledger, so the console shows each step result first and fills the check in afterwards.
- **Console wording:** every step shows Function called, Input and Output (not "under the hood"). Concurrency demos print the INPUT and OUTPUT of each session with timestamps (`DEMO_VERBOSE=1`, set by the console).
- **Disclaimer:** fixed footer at the bottom of every screen.
- **Wallet lists:** `list_wallets` returns the newest wallet first; the Pay screen uses a search-as-you-type wallet picker instead of a long scrolling list.
