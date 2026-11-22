-- Run after db/01_schema.sql through db/05_idempotency.sql.
-- The outer transaction rolls back all fixtures and successful test requests.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    bank_account_id BIGINT;
    fee_account_id BIGINT;
    sender_user_id BIGINT;
    recipient_user_id BIGINT;
    retry_user_id BIGINT;
    drained_user_id BIGINT;
    sender_wallet_id BIGINT;
    recipient_wallet_id BIGINT;
    retry_wallet_id BIGINT;
    drained_wallet_id BIGINT;
    transfer_transaction_id BIGINT;
    refund_origin_transaction_id BIGINT;
    refund_transaction_id BIGINT;
    drained_transfer_id BIGINT;
    returned_transaction_id BIGINT;
    sender_email TEXT;
    recipient_email TEXT;
    retry_email TEXT;
    drained_email TEXT;
    sender_balance BIGINT;
    bank_balance BIGINT;
    fee_balance BIGINT;
    expected_balance NUMERIC;
    transaction_count_before BIGINT;
    entry_count_before BIGINT;
    key_count BIGINT;
    rejected BOOLEAN;
    error_message TEXT;
    fingerprint_one BYTEA;
    fingerprint_two BYTEA;
    account_row RECORD;
BEGIN
    -- Create the system accounts for a reset database; reuse them when they
    -- already exist. The outer rollback removes only fixtures created here.
    INSERT INTO ledger.accounts (code, type)
    VALUES ('BANK', 'asset')
    ON CONFLICT (code) DO NOTHING;

    INSERT INTO ledger.accounts (code, type)
    VALUES ('FEE_INCOME', 'income')
    ON CONFLICT (code) DO NOTHING;

    SELECT id INTO bank_account_id
    FROM ledger.accounts
    WHERE code = 'BANK' AND user_id IS NULL AND type = 'asset';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEST FAILED: a valid BANK system account is unavailable';
    END IF;

    SELECT id INTO fee_account_id
    FROM ledger.accounts
    WHERE code = 'FEE_INCOME' AND user_id IS NULL AND type = 'income';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEST FAILED: a valid FEE_INCOME system account is unavailable';
    END IF;

    sender_email := 'idem-' || md5(clock_timestamp()::TEXT || random()::TEXT) || '@example.test';
    recipient_email := 'idem-' || md5(clock_timestamp()::TEXT || random()::TEXT) || '@example.test';
    retry_email := 'idem-' || md5(clock_timestamp()::TEXT || random()::TEXT) || '@example.test';
    drained_email := 'idem-' || md5(clock_timestamp()::TEXT || random()::TEXT) || '@example.test';

    SELECT ledger.create_user_with_wallet('Idempotency Sender', sender_email)
    INTO sender_user_id;
    SELECT ledger.create_user_with_wallet('Idempotency Recipient', recipient_email)
    INTO recipient_user_id;
    SELECT ledger.create_user_with_wallet('Idempotency Retry Wallet', retry_email)
    INTO retry_user_id;
    SELECT ledger.create_user_with_wallet('Idempotency Drained Wallet', drained_email)
    INTO drained_user_id;

    SELECT id INTO sender_wallet_id FROM ledger.accounts WHERE user_id = sender_user_id;
    SELECT id INTO recipient_wallet_id FROM ledger.accounts WHERE user_id = recipient_user_id;
    SELECT id INTO retry_wallet_id FROM ledger.accounts WHERE user_id = retry_user_id;
    SELECT id INTO drained_wallet_id FROM ledger.accounts WHERE user_id = drained_user_id;

    IF sender_wallet_id IS NULL OR recipient_wallet_id IS NULL
       OR retry_wallet_id IS NULL OR drained_wallet_id IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: test users do not have their wallets';
    END IF;

    -- Fund the sender, then retry a transfer with the same key and payload.
    -- Both calls must return one transaction ID and move funds only once.
    SELECT cached_balance INTO bank_balance
    FROM ledger.accounts WHERE id = bank_account_id;
    SELECT ledger.top_up(sender_wallet_id, 100000, 'idem-topup-main')
    INTO returned_transaction_id;
    IF (SELECT type FROM ledger.transactions WHERE id = returned_transaction_id) <> 'topup' THEN
        RAISE EXCEPTION 'TEST FAILED: keyed top-up did not return its transaction ID';
    END IF;

    SELECT cached_balance INTO fee_balance
    FROM ledger.accounts WHERE id = fee_account_id;
    transaction_count_before := (SELECT COUNT(*) FROM ledger.transactions);
    SELECT ledger.transfer(sender_wallet_id, recipient_wallet_id, 50000, 'idem-transfer-same')
    INTO transfer_transaction_id;
    SELECT ledger.transfer(sender_wallet_id, recipient_wallet_id, 50000, 'idem-transfer-same')
    INTO returned_transaction_id;

    SELECT COUNT(*) INTO key_count
    FROM ledger.idempotency_keys
    WHERE idempotency_key = 'idem-transfer-same';

    IF returned_transaction_id <> transfer_transaction_id
       OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before + 1
       OR key_count <> 1
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id) <> 49750
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = recipient_wallet_id) <> 50000
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = fee_account_id) <> fee_balance + 250
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = bank_account_id) <> bank_balance + 100000 THEN
        RAISE EXCEPTION 'TEST FAILED: same-key transfer replay posted twice or returned a different ID';
    END IF;
    RAISE NOTICE 'TEST PASSED: same key and payload return the original transfer ID';

    -- Reusing the key with a different amount must fail before creating a row.
    transaction_count_before := (SELECT COUNT(*) FROM ledger.transactions);
    entry_count_before := (SELECT COUNT(*) FROM ledger.ledger_entries);
    rejected := FALSE;
    error_message := NULL;
    BEGIN
        PERFORM ledger.transfer(sender_wallet_id, recipient_wallet_id, 50001, 'idem-transfer-same');
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
            GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
    END;
    IF NOT rejected
       OR position('different request' IN lower(error_message)) = 0
       OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before
       OR (SELECT COUNT(*) FROM ledger.ledger_entries) <> entry_count_before THEN
        RAISE EXCEPTION 'TEST FAILED: same key with a different amount was not rejected cleanly';
    END IF;
    RAISE NOTICE 'TEST PASSED: same key with a different payload is rejected';

    -- The operation name is part of the fingerprint, so another operation
    -- cannot reuse the transfer key even if it uses the same wallet and amount.
    rejected := FALSE;
    BEGIN
        PERFORM ledger.top_up(sender_wallet_id, 50000, 'idem-transfer-same');
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before THEN
        RAISE EXCEPTION 'TEST FAILED: a key was reused by a different operation';
    END IF;
    RAISE NOTICE 'TEST PASSED: the same key cannot be reused for another operation';

    -- Per the project decision, omitting a key is an error (rather than an
    -- unkeyed operation). No transaction should be created.
    rejected := FALSE;
    BEGIN
        PERFORM ledger.withdraw(sender_wallet_id, 1, NULL);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before THEN
        RAISE EXCEPTION 'TEST FAILED: a money mover accepted a NULL idempotency key';
    END IF;
    RAISE NOTICE 'TEST PASSED: money movers reject a missing idempotency key';

    -- A failed request stores no key. After funding the wallet, retrying that
    -- key is treated as a new request and succeeds.
    transaction_count_before := (SELECT COUNT(*) FROM ledger.transactions);
    rejected := FALSE;
    BEGIN
        PERFORM ledger.transfer(retry_wallet_id, recipient_wallet_id, 1000, 'idem-retry-after-failure');
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected
       OR EXISTS (
           SELECT 1 FROM ledger.idempotency_keys
           WHERE idempotency_key = 'idem-retry-after-failure'
       )
       OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before THEN
        RAISE EXCEPTION 'TEST FAILED: failed request left an idempotency record or transaction';
    END IF;

    SELECT ledger.top_up(retry_wallet_id, 5000, 'idem-fund-after-failure')
    INTO returned_transaction_id;
    SELECT ledger.transfer(retry_wallet_id, recipient_wallet_id, 1000, 'idem-retry-after-failure')
    INTO transfer_transaction_id;

    IF transfer_transaction_id IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM ledger.idempotency_keys
           WHERE idempotency_key = 'idem-retry-after-failure'
             AND transaction_id = transfer_transaction_id
       ) THEN
        RAISE EXCEPTION 'TEST FAILED: retry after a failed request did not succeed and store its key';
    END IF;
    RAISE NOTICE 'TEST PASSED: failed operations store no key, and a later retry can succeed';

    -- Once the full refund cap has been used, an exact keyed retry still
    -- returns the saved refund instead of re-running the cap check.
    SELECT ledger.transfer(sender_wallet_id, recipient_wallet_id, 10000, 'idem-refund-origin')
    INTO refund_origin_transaction_id;
    SELECT ledger.refund(refund_origin_transaction_id, 10000, 'idem-refund-full')
    INTO refund_transaction_id;
    SELECT ledger.refund(refund_origin_transaction_id, 10000, 'idem-refund-full')
    INTO returned_transaction_id;

    IF returned_transaction_id <> refund_transaction_id
       OR (SELECT COUNT(*) FROM ledger.transactions
           WHERE type = 'refund'
             AND reverses_transaction_id = refund_origin_transaction_id) <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: full-cap refund replay did not return the saved refund';
    END IF;
    RAISE NOTICE 'TEST PASSED: refund replay returns the original ID after the cap is used';

    -- A replay does not re-check the sender's current balance. Spend the
    -- remaining balance after a keyed transfer, then retry it unchanged.
    SELECT ledger.top_up(drained_wallet_id, 20000, 'idem-fund-drained')
    INTO returned_transaction_id;
    SELECT ledger.transfer(drained_wallet_id, recipient_wallet_id, 10000, 'idem-transfer-drained')
    INTO drained_transfer_id;
    sender_balance := (SELECT cached_balance FROM ledger.accounts WHERE id = drained_wallet_id);
    IF sender_balance <> 9900 THEN
        RAISE EXCEPTION 'TEST FAILED: setup for depleted-balance replay has unexpected balance %', sender_balance;
    END IF;
    PERFORM ledger.withdraw(drained_wallet_id, sender_balance, 'idem-drain-wallet');
    transaction_count_before := (SELECT COUNT(*) FROM ledger.transactions);
    SELECT ledger.transfer(drained_wallet_id, recipient_wallet_id, 10000, 'idem-transfer-drained')
    INTO returned_transaction_id;
    IF returned_transaction_id <> drained_transfer_id
       OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = drained_wallet_id) <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: transfer replay was rejected after sender balance dropped';
    END IF;
    RAISE NOTICE 'TEST PASSED: transfer replay returns the saved ID after funds are spent';

    -- Project decision: if an account from the original posting is now frozen,
    -- that status error takes precedence over returning the saved result.
    PERFORM ledger.freeze_account(drained_wallet_id);
    transaction_count_before := (SELECT COUNT(*) FROM ledger.transactions);
    rejected := FALSE;
    error_message := NULL;
    BEGIN
        PERFORM ledger.transfer(drained_wallet_id, recipient_wallet_id, 10000, 'idem-transfer-drained');
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
            GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
    END;
    IF NOT rejected
       OR position('frozen' IN lower(error_message)) = 0
       OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before THEN
        RAISE EXCEPTION 'TEST FAILED: frozen-wallet replay did not return the frozen-account error';
    END IF;
    PERFORM ledger.unfreeze_account(drained_wallet_id);
    RAISE NOTICE 'TEST PASSED: a replay involving a frozen wallet returns the frozen-account error';

    -- Empty and overlong keys are rejected before posting.
    transaction_count_before := (SELECT COUNT(*) FROM ledger.transactions);
    rejected := FALSE;
    BEGIN
        PERFORM ledger.top_up(sender_wallet_id, 100, '');
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: an empty idempotency key was accepted';
    END IF;

    rejected := FALSE;
    BEGIN
        PERFORM ledger.top_up(sender_wallet_id, 100, repeat('x', 201));
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before THEN
        RAISE EXCEPTION 'TEST FAILED: an oversized idempotency key was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: empty and oversized idempotency keys are rejected';

    -- jsonb key order must not change the fingerprint for otherwise identical
    -- arguments. The operation name, in contrast, is included in the hash.
    fingerprint_one := ledger.idempotency_fingerprint(
        'transfer', '{"sender_account_id": 1, "recipient_account_id": 2, "amount": 3}'::jsonb
    );
    fingerprint_two := ledger.idempotency_fingerprint(
        'transfer', '{"amount": 3, "recipient_account_id": 2, "sender_account_id": 1}'::jsonb
    );
    IF fingerprint_one <> fingerprint_two THEN
        RAISE EXCEPTION 'TEST FAILED: reordered JSONB argument keys changed the fingerprint';
    END IF;
    IF fingerprint_one = ledger.idempotency_fingerprint(
        'withdraw', '{"sender_account_id": 1, "recipient_account_id": 2, "amount": 3}'::jsonb
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: operation name was omitted from the fingerprint';
    END IF;
    RAISE NOTICE 'TEST PASSED: fingerprints ignore JSONB key order and include the operation';

    -- Run deferred ledger checks, then independently reconcile all touched
    -- accounts from ledger entries using each type's normal-side convention.
    SET CONSTRAINTS ALL IMMEDIATE;

    FOR account_row IN
        SELECT id, type, cached_balance
        FROM ledger.accounts
        WHERE id = ANY(ARRAY[
            bank_account_id,
            fee_account_id,
            sender_wallet_id,
            recipient_wallet_id,
            retry_wallet_id,
            drained_wallet_id
        ])
    LOOP
        SELECT CASE
            WHEN account_row.type IN ('asset', 'expense') THEN
                COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'debit'), 0)
                - COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'credit'), 0)
            ELSE
                COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'credit'), 0)
                - COALESCE(SUM(e.amount) FILTER (WHERE e.direction = 'debit'), 0)
        END
        INTO expected_balance
        FROM ledger.ledger_entries AS e
        WHERE e.account_id = account_row.id;

        IF account_row.cached_balance <> expected_balance THEN
            RAISE EXCEPTION
                'TEST FAILED: account % cached balance % differs from ledger balance %',
                account_row.id, account_row.cached_balance, expected_balance;
        END IF;
    END LOOP;
    RAISE NOTICE 'TEST PASSED: cached balances reconcile after idempotency scenarios';
END;
$$;

ROLLBACK;
