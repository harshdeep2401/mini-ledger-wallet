// The scripted demo scenarios. Amounts are paise (₹1 = 100). Each step says what it
// EXPECTS (accepted or rejected), so the screen can show whether the database behaved.
// Fixed statements only: nothing here is built from user input.
const rupees = (paise) => `₹${(Number(paise) / 100).toLocaleString('en-IN', { minimumFractionDigits: 2 })}`;

const alice = (funding) => ({ key: 'alice', name: 'Alice', funding });
const bob = (funding = 0) => ({ key: 'bob', name: 'Bob', funding });

export const scenarios = [
  // ---------------------------------------------------------------- money in and out
  {
    id: 'bank-in-out', group: 'Money in and out', title: 'Bank → wallet and back',
    description: 'Money enters from the BANK account, leaves back to it, and is refused when the wallet cannot cover it.',
    people: [alice(0)],
    steps: [
      { title: 'Top up Alice with ₹1,000', expect: 'accepted', watch: ['alice'],
        say: 'Money enters the system from the BANK account: BANK is debited, Alice\'s wallet is credited.',
        run: async (h, c) => ({ transactionId: await h.topUp(c.alice.id, 100000, 'topup') }) },
      { title: 'Withdraw ₹200', expect: 'accepted', watch: ['alice'],
        say: 'The reverse direction: Alice is debited, BANK is credited.',
        run: async (h, c) => ({ transactionId: await h.withdraw(c.alice.id, 20000, 'withdraw') }) },
      { title: 'Try to withdraw ₹5,000', expect: 'rejected', watch: ['alice'],
        say: 'Alice has ₹800. The database refuses and nothing is written.',
        run: async (h, c) => ({ transactionId: await h.withdraw(c.alice.id, 500000, 'withdraw-big') }) },
      { title: 'Try to top up a negative amount', expect: 'rejected', watch: ['alice'],
        say: 'Amounts must be positive. The rule is in the database, not in the app.',
        run: async (h, c) => ({ transactionId: await h.topUp(c.alice.id, -5000, 'topup-negative') }) },
    ],
  },

  // ---------------------------------------------------------------------- the fee
  {
    id: 'transfer-fee', group: 'Fees', title: 'Transfer with a fee',
    description: 'Every transfer adds a fee that goes to FEE_INCOME: three legs that still balance.',
    people: [alice(1000000), bob()],
    steps: [
      { title: 'The fee rule: 0.5%, minimum ₹1, maximum ₹10', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'calculate_fee() is a database function. The same amounts, three sizes.',
        run: async (h) => {
          const rows = [];
          for (const amount of [5000, 50000, 500000]) rows.push([`Fee on ${rupees(amount)}`, rupees(await h.fee(amount))]);
          return { rows };
        } },
      { title: 'Transfer ₹500 from Alice to Bob', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'Three legs: Alice pays ₹500 plus the fee, Bob receives ₹500, FEE_INCOME receives the fee.',
        run: async (h, c) => ({ transactionId: await h.transfer(c.alice.id, c.bob.id, 50000, 't500') }) },
      { title: 'Transfer ₹50 (minimum fee applies)', expect: 'accepted', watch: ['alice', 'bob'],
        say: '0.5% of ₹50 is 25 paise, so the ₹1 minimum is charged.',
        run: async (h, c) => ({ transactionId: await h.transfer(c.alice.id, c.bob.id, 5000, 't50') }) },
      { title: 'Transfer ₹5,000 (maximum fee applies)', expect: 'accepted', watch: ['alice', 'bob'],
        say: '0.5% of ₹5,000 is ₹25, so the ₹10 cap is charged.',
        run: async (h, c) => ({ transactionId: await h.transfer(c.alice.id, c.bob.id, 500000, 't5000') }) },
      { title: 'Try to send ₹4,430 when Alice has ₹4,436.50', expect: 'rejected', watch: ['alice', 'bob'],
        say: 'The fee counts too: ₹4,430 + ₹10 is more than Alice has, so nothing moves.',
        run: async (h, c) => ({ transactionId: await h.transfer(c.alice.id, c.bob.id, 443000, 'too-much') }) },
    ],
  },

  // ---------------------------------------------------------------------- refunds
  {
    id: 'refunds', group: 'Refunds', title: 'Refunds',
    description: 'A refund is a new transaction that points at the original. The original is never edited.',
    people: [alice(1000000), bob()],
    steps: [
      { title: 'Transfer ₹500 from Alice to Bob', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'The payment we will refund.',
        run: async (h, c, s) => { s.original = await h.transfer(c.alice.id, c.bob.id, 50000, 'orig'); return { transactionId: s.original }; } },
      { title: 'Refund ₹200 (partial)', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'A new transaction with its own legs. Look at "reverses transaction" and at FEE_INCOME.',
        run: async (h, c, s) => ({ transactionId: await h.refund(s.original, 20000, 'ref-200') }) },
      { title: 'Try to refund ₹400 more', expect: 'rejected', watch: ['alice', 'bob'],
        say: 'Only ₹300 of the original is left to refund.',
        run: async (h, c, s) => ({ transactionId: await h.refund(s.original, 40000, 'ref-400') }) },
      { title: 'Refund the remaining ₹300', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'Exactly the remaining amount is allowed.',
        run: async (h, c, s) => ({ transactionId: await h.refund(s.original, 30000, 'ref-300') }) },
      { title: 'Try to refund ₹1 more', expect: 'rejected', watch: ['alice', 'bob'],
        say: 'The original is fully refunded now.',
        run: async (h, c, s) => ({ transactionId: await h.refund(s.original, 100, 'ref-1') }) },
      { title: 'Look at the original transaction again', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'Same three legs as before. History is append-only; corrections are new rows.',
        run: async (h, c, s) => ({ transactionId: s.original }) },
    ],
  },

  // ---------------------------------------------------------------------- failures
  {
    id: 'blocked-payments', group: 'When it fails', title: 'Overdraft and frozen accounts',
    description: 'The database refuses payments it should refuse, and allows them again once the cause is fixed.',
    people: [alice(100000), bob()],
    steps: [
      { title: 'Try to send ₹5,000 with only ₹1,000', expect: 'rejected', watch: ['alice', 'bob'],
        say: 'Insufficient funds.',
        run: async (h, c) => ({ transactionId: await h.transfer(c.alice.id, c.bob.id, 500000, 'overdraw') }) },
      { title: 'Try to send ₹0', expect: 'rejected', watch: ['alice', 'bob'],
        say: 'Zero is not a valid amount.',
        run: async (h, c) => ({ transactionId: await h.transfer(c.alice.id, c.bob.id, 0, 'zero') }) },
      { title: 'Admin freezes Bob\'s account', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'Done by the separate ledger_admin login.',
        run: async (h, c) => { await h.freeze(c.bob.id); return { notes: ['Bob is now frozen.'] }; } },
      { title: 'Try to send ₹100 to frozen Bob', expect: 'rejected', watch: ['alice', 'bob'],
        say: 'A frozen account cannot be posted to.',
        run: async (h, c) => ({ transactionId: await h.transfer(c.alice.id, c.bob.id, 10000, 'to-frozen') }) },
      { title: 'Admin unfreezes Bob', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'Back to normal.',
        run: async (h, c) => { await h.unfreeze(c.bob.id); return { notes: ['Bob is active again.'] }; } },
      { title: 'Send ₹100 to Bob again', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'Same payment, now it works.',
        run: async (h, c) => ({ transactionId: await h.transfer(c.alice.id, c.bob.id, 10000, 'to-active') }) },
    ],
  },

  // ---------------------------------------------------------------------- idempotency
  {
    id: 'double-click', group: 'When it fails', title: 'Double-click and retries (idempotency)',
    description: 'The same request sent again is applied once. A different request under the same key is refused.',
    people: [alice(100000), bob()],
    steps: [
      { title: 'Pay Bob ₹100 with key K', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'The first request with this key.',
        run: async (h, c, s) => { s.key = h.key('same-key'); s.first = await h.transferWithKey(c.alice.id, c.bob.id, 10000, s.key); return { transactionId: s.first }; } },
      { title: 'The network dropped: retry the exact same request', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'Same key, same amount. The stored answer comes back and no second charge happens.',
        run: async (h, c, s) => {
          const again = await h.transferWithKey(c.alice.id, c.bob.id, 10000, s.key);
          if (String(again) !== String(s.first)) throw new Error('retry created a second transaction');
          return { transactionId: again, notes: [`Same transaction id as step 1 (${again}). Balances did not change.`] };
        } },
      { title: 'Same key but a different amount (₹150)', expect: 'rejected', watch: ['alice', 'bob'],
        say: 'A key may not be reused for a different request.',
        run: async (h, c, s) => ({ transactionId: await h.transferWithKey(c.alice.id, c.bob.id, 15000, s.key) }) },
      { title: 'Two identical requests at the same instant', expect: 'accepted', watch: ['alice', 'bob'],
        say: 'Like a real double-click. Exactly one transaction must result.',
        run: async (h, c) => {
          const key = h.key('instant');
          const settled = await Promise.allSettled([
            h.transferWithKey(c.alice.id, c.bob.id, 20000, key),
            h.transferWithKey(c.alice.id, c.bob.id, 20000, key),
          ]);
          const ids = [...new Set(settled.filter((r) => r.status === 'fulfilled').map((r) => String(r.value)))];
          const rows = settled.map((r, i) => [`Request ${i + 1}`,
            r.status === 'fulfilled' ? `transaction ${r.value}` : `refused: ${r.reason.message}`]);
          if (ids.length !== 1) throw new Error(`expected exactly one transaction, got ${ids.length}`);
          return { transactionId: ids[0], rows };
        } },
    ],
  },

  // ---------------------------------------------------------------------- break it
  {
    id: 'break-it', group: 'Try to break it', title: 'Try to break the ledger',
    description: 'Play a buggy or malicious developer. Each attempt runs in a transaction that is always rolled back.',
    people: [alice(100000)],
    steps: [
      { title: 'UPDATE a ledger entry (even as the table owner)', expect: 'rejected', watch: ['alice'],
        say: 'History is append-only. A trigger refuses edits from every role.',
        run: (h) => h.attack('ledger_owner', ['UPDATE ledger.ledger_entries SET amount = 1 WHERE id = (SELECT max(id) FROM ledger.ledger_entries)']) },
      { title: 'DELETE every ledger entry (as the owner)', expect: 'rejected', watch: ['alice'],
        say: 'Deletes are refused by the same trigger.',
        run: (h) => h.attack('ledger_owner', ['DELETE FROM ledger.ledger_entries']) },
      { title: 'DELETE entries as the application login', expect: 'rejected', watch: ['alice'],
        say: 'The app login has no table privileges at all.',
        run: (h) => h.attack('ledger_app', ['DELETE FROM ledger.ledger_entries']) },
      { title: 'Edit a balance directly as the application login', expect: 'rejected', watch: ['alice'],
        say: 'The cached balance can only change through the ledger functions.',
        run: (h) => h.attack('ledger_app', ['UPDATE ledger.accounts SET cached_balance = 99999999']) },
      { title: 'Insert a debit with no matching credit, then commit', expect: 'rejected', watch: ['alice'],
        say: 'The balance check is deferred to commit, so a one-sided transaction cannot be saved.',
        run: async (h, c) => h.attack('ledger_owner', [
          "INSERT INTO ledger.transactions (type) VALUES ('topup')",
          `INSERT INTO ledger.ledger_entries (transaction_id, account_id, direction, amount)
             SELECT max(id), ${Number(c.alice.id)}, 'debit', 100 FROM ledger.transactions`,
          'SET CONSTRAINTS ALL IMMEDIATE', // the same check that COMMIT would run
        ]) },
      { title: 'Insert an entry with amount −50', expect: 'rejected', watch: ['alice'],
        say: 'A CHECK constraint refuses non-positive amounts.',
        run: async (h, c) => h.attack('ledger_owner', [
          "INSERT INTO ledger.transactions (type) VALUES ('topup')",
          `INSERT INTO ledger.ledger_entries (transaction_id, account_id, direction, amount)
             SELECT max(id), ${Number(c.alice.id)}, 'debit', -50 FROM ledger.transactions`,
        ]) },
    ],
  },

  // ---------------------------------------------------------------------- tamper
  {
    id: 'tamper', group: 'Try to break it', title: 'Reconciliation catches tampering',
    description: 'Corrupt a cached balance behind the ledger\'s back. The ledger check notices, and then we repair it.',
    people: [alice(100000)],
    steps: [
      { title: 'Check the ledger', expect: 'accepted', watch: ['alice'],
        say: 'Every entry is re-added from scratch and compared with the stored balances.',
        run: async () => ({ notes: ['The ledger check runs after every step; see the badge below.'] }) },
      { title: 'Corrupt Alice\'s stored balance (set it to ₹999,999.99)', expect: 'accepted', watch: ['alice'], expectHealthy: false,
        say: 'A deliberate attack on the cached column, done as the owner. The write succeeds; the question is whether anyone notices.',
        run: async (h, c, s) => {
          const [row] = await h.call('app', 'get_balance', 'SELECT ledger.get_balance($1) AS balance', [c.alice.id]);
          s.tampered = { id: c.alice.id, original: Number(row.balance) };
          await h.ownerWrite('UPDATE ledger.accounts SET cached_balance = 99999999 WHERE id = $1', [c.alice.id]);
          return { notes: ['Cached balance overwritten.'] };
        } },
      { title: 'Check the ledger again', expect: 'accepted', watch: ['alice'], expectHealthy: false,
        say: 'The check catches it and reports expected versus actual.',
        run: async (h) => {
          const issues = await h.issues();
          return { rows: issues.slice(0, 5).map((i) => [`${i.check_name} (account ${i.account_id ?? '-'})`, `expected ${i.expected}, actual ${i.actual}`]) };
        } },
      { title: 'Repair the balance', expect: 'accepted', watch: ['alice'],
        say: 'Restore the cached value from the entries. The ledger is healthy again.',
        run: async (h, c, s) => {
          await h.ownerWrite('UPDATE ledger.accounts SET cached_balance = $2 WHERE id = $1', [s.tampered.id, s.tampered.original]);
          s.tampered = null;
          return { notes: ['Cached balance restored.'] };
        } },
    ],
  },
];
