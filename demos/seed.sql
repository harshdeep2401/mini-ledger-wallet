-- Deliberate, persistent demo seed. Run with `npm run db:seed:demo`.
-- All money movements go through the public operation functions. Stable
-- emails and idempotency keys make reruns safe; don't reuse these demo wallets
-- for unrelated development data if you want to keep the stated balances.
BEGIN;

DO $$
DECLARE
    alice_user_id BIGINT;
    bob_user_id BIGINT;
    alice_wallet_id BIGINT;
    bob_wallet_id BIGINT;
BEGIN
    SELECT id INTO alice_user_id
    FROM ledger.users
    WHERE email = 'alice.demo@mini-ledger.test';

    IF alice_user_id IS NULL THEN
        alice_user_id := ledger.create_user_with_wallet(
            'Alice Demo', 'alice.demo@mini-ledger.test'
        );
    END IF;

    SELECT id INTO bob_user_id
    FROM ledger.users
    WHERE email = 'bob.demo@mini-ledger.test';

    IF bob_user_id IS NULL THEN
        bob_user_id := ledger.create_user_with_wallet(
            'Bob Demo', 'bob.demo@mini-ledger.test'
        );
    END IF;

    SELECT id INTO alice_wallet_id
    FROM ledger.accounts
    WHERE user_id = alice_user_id AND type = 'liability';

    SELECT id INTO bob_wallet_id
    FROM ledger.accounts
    WHERE user_id = bob_user_id AND type = 'liability';

    -- ₹1,000 starting balance, then Alice sends ₹500. The fee is ₹2.50.
    PERFORM ledger.top_up(alice_wallet_id, 100000, 'demo-alice-topup-v1');
    PERFORM ledger.transfer(
        alice_wallet_id, bob_wallet_id, 50000, 'demo-alice-to-bob-500-v1'
    );

    IF NOT ledger.reconciliation_summary() THEN
        RAISE EXCEPTION 'demo seed finished with reconciliation issues';
    END IF;
END;
$$;

COMMIT;
