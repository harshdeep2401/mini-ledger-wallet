# Extended Features

Optional features to make the project feel like a live system rather than a scripted demo. Features 1–5 are built (the **user dashboard** and the **admin dashboard**, both behind a log-in); the smaller extras are not. All of them keep the project's rules: business logic stays in the database, the server stays thin, and it remains a **simulation only, never real money**.

**The main idea:** money moves on screen continuously, and the database proves the books still balance while it moves.

---

## Recommended build order

| # | Feature | Why it impresses | Status |
|---|---------|------------------|--------|
| 1 | Traffic simulator | Many users paying each other at once, live | Built |
| 2 | Admin live feed (LISTEN/NOTIFY) | Transactions appear instantly, pushed by Postgres | Built |
| 3 | Admin dashboard + live reconciliation | "2,000 transactions, books still at ₹0 difference" | Built |
| 4 | Transaction tracer | Click any payment, see every leg and its refunds | Built |
| 5 | Per-user login, checked in the database | Fixes the "anyone can read any wallet" limitation | Built |

**Where it lives:** `db/11_admin_monitor.sql` (notify trigger, `recent_transactions`, `ledger_stats`, `transaction_refunds`, admin/reporting only), `server/live.js` (LISTEN → Server-Sent Events), `server/simulator.js`, `server/admin.js` (`/api/admin/*`), `client/src/admin/`.

**Apply to an existing database:** `node --env-file=.env scripts/apply-file.mjs db/11_admin_monitor.sql` (a fresh `db:reset` includes it).

**Demo flow:** log in as admin → Dashboard → Start simulator → watch the feed and the `BANK = wallets + fees` line stay at ₹0 difference → click a transfer to trace it → switch to Demo console, run the tamper act, come back and see reconciliation turn red.

Features 1–3 together give the wow factor. 4 and 5 are good if there is time.

---

## 1. Traffic simulator

A script (`demos/traffic.mjs`) creates 20–50 simulated users and keeps calling the existing functions at random: top-ups, transfers, withdrawals, refunds, plus some deliberate failures (overspend, frozen wallet, repeated idempotency key).

- **DB:** nothing new. It uses the current functions as `ledger_app`.
- **Server/UI:** a Start/Stop button on the admin page and a rate setting (2–20 per second, up to 8 requests in flight). Simulated users have `@trafficsim.example` emails and are reused between runs. It stops by itself after 10 minutes.
- **Demo line:** "This is 50 users using the wallet at the same time. Watch the admin page."

## 2. Admin live feed (LISTEN/NOTIFY)

A trigger on `transactions` calls `pg_notify('ledger_events', ...)` with the transaction id, type and amount. The server keeps one `LISTEN` connection and forwards each event to the browser with Server-Sent Events. The admin page shows a scrolling feed: time, type, from → to, amount, fee.

- **DB:** `db/11_admin_monitor.sql` with the notify trigger, plus an admin-only `recent_transactions(limit)` read function so the feed fills in on page load. (This function was removed earlier because it was not needed; here it is admin-only.)
- **Server:** `GET /api/admin/events` (SSE). Neon's `-pooler` address cannot hold a `LISTEN`, so the listener uses the direct address of the same database. It fetches exactly the announced ids, because commits can finish out of order.
- **Viva point:** transaction ids in the feed have gaps. A rejected payment rolls back but has already used an identity value; sequences are never rolled back.
- **Why it is a DBMS point:** Postgres pushes the event, and it is sent only after **commit**. A rolled-back payment never shows up in the feed, which you can demonstrate.

## 3. Admin dashboard + live reconciliation

Tiles that refresh every few seconds:
- total wallet balances, BANK position, FEE_INCOME earned
- transactions per minute, refunds, rejected attempts
- reconciliation badge: **green "0 issues"** while the simulator is running

- **DB:** one admin read function `ledger_stats()` returning the totals in one query, including `books_difference = BANK − wallets − FEE_INCOME`, which the accounting equation says is always 0.
- **Rejected attempts** are counted by the simulator (the database keeps no record of a rolled-back payment).
- **Demo line:** run the simulator, then run the tamper act from the demo console and watch the badge turn red.

## 4. Transaction tracer

Click any feed row to open its detail: every ledger leg (debit/credit, account, amount), the fee leg, the idempotency key, refunds made against it, and how much is left to refund.

- **DB:** the existing `get_transaction(id)` plus a new `transaction_refunds(id)` (refunds and what is left to refund).
- **UI:** a side panel on the admin page.

## 5. Per-user login, checked in the database

Sign up or log in as a **Wallet user** on the landing page. The database checks the password and returns a session token; every later request carries it and the database works out the wallet from it.

- **DB (`db/12_auth.sql`):** `user_credentials` (bcrypt hash via pgcrypto, failed-attempt count, lock time) and `sessions` (SHA-256 of the token, expiry 8 hours, revoked time). Functions `sign_up`, `log_in`, `log_out`, `my_wallet`, `my_history`, `find_recipients` (name and masked email, no balance), `my_top_up`, `my_withdraw`, `my_transfer`, `my_refund`.
- **New login `ledger_web`:** the only login the browser-facing routes use. It can call only the functions above (plus `calculate_fee`), never `transfer(sender, …)` or `get_balance(any id)`, and no table. `ledger_app` keeps the unscoped functions for trusted internal tools (demo console, simulator, tests).
- **Rules:** money always leaves the token's own wallet (there is no "from" field); only the receiver of a transfer can refund it; 5 wrong passwords lock the email for 5 minutes; an unknown email gets the same answer as a wrong password.
- **Viva point:** `log_in` returns failure as a value instead of raising an exception, because an exception would roll back the failure count it just recorded.
- **Server:** `/api/auth/*` and `/api/me/*`. The token travels as `Authorization: Bearer …`; the server passes it to the database and maps SQLSTATE `P1002` to 401.
- **Setup:** `npm run server:setup-logins` (adds `WEB_DATABASE_URL`), then `npm run db:seed:logins` (Riya and Kabir, `demo-password`).

### 5b. Admin log-in (`db/13_admin_auth.sql`)

- Admins are a separate table with their own sessions; an admin has no wallet, and a user token is never an admin token.
- **Sign-up is invite-only:** a single-use code, stored as SHA-256, created only by the owner (`npm run db:seed:logins` prints a fresh one). The invite row is locked during sign-up so a code cannot be used twice.
- **Every admin action is a token-checked function** (`admin_stats`, `admin_feed`, `admin_wallets`, `admin_freeze`, `admin_reconciliation`, …), granted to `ledger_web`. The live feed, simulator and demo console routes first call `admin_me(token)`.
- There is no built-in admin: sign up with the invite code that `npm run db:seed:logins` prints.

---

## Smaller extras (pick any)

- **Balance as of a time:** `balance_at(account_id, timestamp)` summed from ledger entries. Shows why the ledger, not the cached balance, is the source of truth.
- **Daily limits:** reject a transfer if the wallet's daily total would pass a limit (for example ₹50,000). This is a new business rule, so it goes in the DB as a `P1001` error.
- **Rejected-attempt log:** failed payments roll back, so nothing records them today. The server would call a separate `log_rejection(...)` function in its own transaction after a `P1001` error.
- **Stress button:** fire 500 concurrent transfers from the admin page and show throughput, deadlocks (0) and reconciliation (0 issues).
- **Statements:** a monthly statement per wallet from a materialized view, refreshed by an admin function.

## Out of scope

- Real payments, real banks, or real UPI. This stays a simulation.
- Moving any money rules into the server or React.
