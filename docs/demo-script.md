# Demo script

About 20 minutes. Open the **Demo console** tab. Everything below is a click on **Next step**; each result shows the function called, the input, the output, the ledger legs and the balances.

**Before you start**
- `npm run server` and `npm run client:dev` are running.
- Pick any act and press Next once: the "Ledger healthy ✅" line should appear.
- Keep psql or the Neon console open in case someone asks to see a table.
- Each scenario creates fresh Alice and Bob wallets, so the numbers below repeat.

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

## Closing
> "Money is never a number I update. It's the sum of immutable entries, and Postgres refuses anything that doesn't balance, rewrites history, overdraws or double-charges."

## If something goes wrong
- **Ledger check red before the tamper act:** run the tamper scenario to the end (the repair step), or leave it. Leaving a scenario also repairs it.
- **Concurrency demo says another is running:** wait for it to finish.
- **Console shows a 503:** the server's `.env` is missing `APP_DATABASE_URL` or `ADMIN_DATABASE_URL`; run `npm run server:setup-logins`.
