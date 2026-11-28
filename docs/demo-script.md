# Demo script

About 25 minutes. Log in with your admin account (created once with **Admin → Sign up** and an invite code from `npm run db:seed:logins`). Parts 0–8 use **Admin → Demo console**: everything is a click on **Next step**, and each result shows the function called, the input, the output, the ledger legs and the balances. Part 9 uses the user dashboard, part 10 **Admin → Dashboard**.

**Before you start**
- `npm run server` and `npm run client:dev` are running.
- Pick any act and press Next once: the "Ledger healthy ✅" line should appear.
- Keep psql or the Neon console open in case someone asks to see a table.
- Each scenario creates fresh Alice and Bob wallets, so the numbers below repeat.
- `npm run db:seed:logins` has been run. For part 9, open a second browser window (or a private window) so you can stay logged in as admin in the first.
- Admin → Dashboard shows "● LIVE" next to the feed title.

## 0. Pitch (1 min) — *Start here*
> "The database itself guarantees money can't be created, lost, double-spent or silently edited, even if the app is buggy. The server has no `if balance < amount` anywhere. It calls one database function per request."

Point at the diagram: browser → server → PostgreSQL.

## 1. Money in and out (2 min) — *Bank → wallet and back*
1. **Top up ₹1,000:** debit BANK, credit Alice. Two legs, debits = credits.
2. **Withdraw ₹200:** the reverse; Alice drops to ₹800.
3. **Withdraw ₹5,000:** refused, "insufficient funds". Balances unchanged.
4. **Negative top-up:** refused. The rule lives in the database.

> "Amounts are integer paise, never floats. Money enters and leaves through the BANK account, so the books always balance."

## 2. The fee (3 min) — *Transfer with a fee*
1. **Fee rule:** ₹50 → ₹1 (minimum), ₹500 → ₹2.50, ₹5,000 → ₹10 (maximum).
2. **Transfer ₹500:** three legs. Alice −₹502.50, Bob +₹500, FEE_INCOME +₹2.50. Show FEE_INCOME growing in the balances table.
3. **₹50 and ₹5,000:** the minimum and maximum fee in action.
4. **Send ₹4,430 with ₹4,436.50:** refused, because the fee counts too.

> "0.5%, minimum ₹1, maximum ₹10. The fee is calculated in the database, so no client can skip it."

## 3. Refunds (2 min) — *Refunds*
1. Transfer ₹500.
2. **Refund ₹200:** a new transaction; the chip shows it reverses the original. The fee is not returned.
3. **Refund ₹400 more:** refused, "remaining refundable amount of 30000 paise".
4. **Refund the remaining ₹300:** allowed. **Another ₹1:** refused.
5. **Look at the original:** same three legs as before.

> "A refund is a new transaction. History is never edited."

## 4. When it fails (3 min) — *Overdraft and frozen accounts*, then *Double-click and retries*
Frozen account:
1. Overdraft and ₹0: refused.
2. Admin freezes Bob (the separate `ledger_admin` login).
3. Pay frozen Bob: refused. Unfreeze, pay again: works.

Double-click:
1. Pay ₹100 with key K.
2. **Retry the same request:** same transaction id, balances unchanged. No second charge.
3. **Same key, ₹150:** refused.
4. **Two identical requests at once:** one succeeds; the other is refused as "already in progress" or returns the same id.

> "The UI makes one key per click. The database enforces it, so even a buggy client can't charge twice."

## 5. Try to break it (3 min) — *Try to break the ledger*
Six attempts, each refused with the real database error, each rolled back:
1. UPDATE an entry (as the table owner): "append-only".
2. DELETE all entries (as the owner): same.
3. DELETE as the app login: "permission denied".
4. Edit a balance as the app login: "permission denied".
5. Debit with no credit, then commit: "unbalanced: debits 100 != credits 0".
6. Amount of −50: check constraint.

> "The balance check waits until commit, because the legs are inserted one at a time. Even if the API had a bug, none of these could reach the ledger."

## 6. Reconciliation (1 min) — *Reconciliation catches tampering*
1. Ledger healthy.
2. **Corrupt Alice's stored balance:** the write succeeds, and the check turns red.
3. **Check again:** "expected 100000, actual 99999999".
4. **Repair:** healthy again.

> "The cached balance is only for speed. The truth is the entries, and reconciliation re-adds all of them (about a second for 127,000 transactions)."

## 7. Concurrency (3 min) — *Concurrency*
Run **Double-spend**: the broken version lets both ₹800 withdrawals through and the balance goes to −₹600; the real one refuses the second. Read the INPUT and OUTPUT lines to show the two sessions overlapping.

Run **Deadlock**: the broken version aborts one transfer with `40P01`; the real function locks the lower account id first and never deadlocks (20 opposite transfers, 0 failures).

Run **Idempotency**: eight sessions with one key give one transaction and seven "already in progress".

> "Both sessions read ₹1,000 before either wrote. The fix is `SELECT … FOR UPDATE`. For deadlocks, lock in a global order, so a cycle can't form."

## 8. Performance (2 min) — *Performance*
- History page: 89 ms without the index, 0.15 ms with it (about 600×).
- Page 5,000: OFFSET 225 ms, keyset 0.09 ms.
- Cached balance 0.15 ms vs recomputing 64 ms.

> "Equality column first, then the sort columns, so the index already holds rows in the order we want. OFFSET has to build and throw away every skipped row."

## 9. Logging in (3 min) — *User dashboard*
1. **Log in as Riya** (`riya.demo@mini-ledger.test`, `demo-password`) as a Wallet user. Balance and recent activity appear.
2. **Transfer ₹500 to Kabir:** the review shows the ₹2.50 fee before you confirm. Note there is no "From" field.
3. **Log out, log in as Kabir,** and refund Riya's payment from his recent activity. Riya can't refund her own payment: the button isn't shown, and the database would refuse it anyway.
4. **Try an admin URL with a user token:** refused (401). Admin actions check for an *admin* token inside the database.
5. **Wrong password 5 times:** "too many failed attempts". The email is locked for 5 minutes.

> "The browser login, `ledger_web`, can only call functions that take a session token. The database turns the token into the wallet, so a request can't even name someone else's wallet. Passwords are bcrypt hashes and tokens are stored as SHA-256, both inside Postgres."

## 10. Live traffic (3 min) — *Admin → Dashboard*
1. **Start the simulator at 10/sec.** Thirty simulated users start paying each other. The live feed scrolls and the counters move.
2. **Point at the rejections:** overspends, self-transfers and over-refunds, each with the database's own message. "Retries replayed" is the double-click case happening at scale.
3. **Point at the equation:** `BANK = all wallets + fee income`, difference ₹0, and reconciliation green, while money is moving.
4. **Click any transfer in the feed:** the tracer shows its legs (debits = credits) and any refunds with what is left to refund.
5. **Optional:** switch to Demo console, run the tamper act, switch back, and the reconciliation tile is red until the act repairs it.

> "The feed is pushed by Postgres itself: a trigger calls `NOTIFY`, which is delivered only at commit, so a rejected payment never appears. The ids have gaps because a rolled-back payment still used up a sequence number."

## Closing
> "Money is never a number I update. It's the sum of immutable entries, and Postgres refuses anything that doesn't balance, rewrites history, overdraws or double-charges."

## If something goes wrong
- **Ledger check red before the tamper act:** run the tamper scenario to the end (the repair step), or leave it. Leaving a scenario also repairs it.
- **Concurrency demo says another is running:** wait for it to finish.
- **A page shows a 503:** the server's `.env` is missing `APP_DATABASE_URL`, `ADMIN_DATABASE_URL` or `WEB_DATABASE_URL`; run `npm run server:setup-logins` and restart the server.
- **Feed says "reconnecting":** restart `npm run server`. The listener uses Neon's direct (non-pooler) address.
- **A log-in is locked:** wait 5 minutes, or run `npm run db:seed:logins` again (it resets the lock).
