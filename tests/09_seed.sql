-- Seed checks are conditional so the normal test suite also works before
-- either persistent seed has been run. All changes in this file roll back.
-- The demo balance check assumes the demo wallets have not been used since
-- seeding; reset and rerun `npm run db:seed:demo` before checking after a live demo.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    alice_balance BIGINT;
    bob_balance BIGINT;
    performance_wallet_count BIGINT;
    performance_transaction_count BIGINT;
    performance_entry_count BIGINT;
    issue_count BIGINT;
BEGIN
    IF EXISTS (
        SELECT 1 FROM ledger.users
        WHERE email IN ('alice.demo@mini-ledger.test', 'bob.demo@mini-ledger.test')
    ) THEN
        SELECT a.cached_balance INTO alice_balance
        FROM ledger.users AS u
        JOIN ledger.accounts AS a ON a.user_id = u.id
        WHERE u.email = 'alice.demo@mini-ledger.test';

        SELECT a.cached_balance INTO bob_balance
        FROM ledger.users AS u
        JOIN ledger.accounts AS a ON a.user_id = u.id
        WHERE u.email = 'bob.demo@mini-ledger.test';

        IF alice_balance IS DISTINCT FROM 49750 OR bob_balance IS DISTINCT FROM 50000 THEN
            RAISE EXCEPTION
                'TEST FAILED: demo seed balances are Alice %, Bob % paise; expected 49750 and 50000',
                alice_balance, bob_balance;
        END IF;
        RAISE NOTICE 'TEST PASSED: demo seed Alice and Bob balances match the ₹500 transfer story';
    ELSE
        RAISE NOTICE 'TEST SKIPPED: demo seed has not been run';
    END IF;

    SELECT COUNT(*) INTO performance_wallet_count
    FROM ledger.users
    WHERE email LIKE 'perf-wallet-%@mini-ledger.test';

    IF performance_wallet_count > 0 THEN
        SELECT COUNT(*) INTO performance_transaction_count
        FROM ledger.transactions
        WHERE idempotency_key LIKE 'perf-v1-%';

        SELECT COUNT(*) INTO performance_entry_count
        FROM ledger.ledger_entries AS e
        JOIN ledger.transactions AS t ON t.id = e.transaction_id
        WHERE t.idempotency_key LIKE 'perf-v1-%';

        SELECT COUNT(*) INTO issue_count FROM ledger.reconciliation_issues();
        IF performance_wallet_count <> 1000
           OR performance_transaction_count <> 127000
           OR performance_entry_count <> 374000
           OR NOT ledger.reconciliation_summary()
           OR issue_count <> 0 THEN
            RAISE EXCEPTION
                'TEST FAILED: performance seed incomplete or unhealthy (wallets %, transactions %, entries %, issues %)',
                performance_wallet_count, performance_transaction_count,
                performance_entry_count, issue_count;
        END IF;
        RAISE NOTICE 'TEST PASSED: full performance seed contains 374,000 reconciled entries';
    ELSE
        RAISE NOTICE 'TEST SKIPPED: performance seed has not been run';
    END IF;

    IF NOT ledger.reconciliation_summary()
       OR EXISTS (SELECT 1 FROM ledger.reconciliation_issues()) THEN
        RAISE EXCEPTION 'TEST FAILED: current ledger does not reconcile';
    END IF;
    RAISE NOTICE 'TEST PASSED: current ledger reconciles';
END;
$$;

ROLLBACK;
