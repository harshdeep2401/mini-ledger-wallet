-- Run after db/01_schema.sql, db/02_triggers.sql, and db/03_posting.sql.
-- Fixtures and successful postings are rolled back at the end.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    bank_account_id BIGINT;
    sender_account_id BIGINT;
    recipient_account_id BIGINT;
    fee_account_id BIGINT;
    frozen_account_id BIGINT;
    missing_account_id BIGINT;
    fixture_account_ids BIGINT[];
    test_transaction_id BIGINT;
    transaction_count_before BIGINT;
    entry_count_before BIGINT;
    expected_balance BIGINT;
    account_row RECORD;
    rejected BOOLEAN;
BEGIN
    INSERT INTO accounts (code, type)
    VALUES ('POSTING_TEST_BANK', 'asset')
    RETURNING id INTO bank_account_id;

    INSERT INTO accounts (code, type)
    VALUES ('POSTING_TEST_SENDER', 'liability')
    RETURNING id INTO sender_account_id;

    INSERT INTO accounts (code, type)
    VALUES ('POSTING_TEST_RECIPIENT', 'liability')
    RETURNING id INTO recipient_account_id;

    INSERT INTO accounts (code, type)
    VALUES ('POSTING_TEST_FEE_INCOME', 'income')
    RETURNING id INTO fee_account_id;

    INSERT INTO accounts (code, type, status)
    VALUES ('POSTING_TEST_FROZEN', 'liability', 'frozen')
    RETURNING id INTO frozen_account_id;

    fixture_account_ids := ARRAY[
        bank_account_id,
        sender_account_id,
        recipient_account_id,
        fee_account_id,
        frozen_account_id
    ];

    -- Seed the sender wallet with a valid top-up, then post the Phase 1
    -- transfer: debit 505, credit 500, and credit fee income 5.
    PERFORM post_transaction(
        'topup',
        jsonb_build_array(
            jsonb_build_object('account_id', bank_account_id, 'direction', 'debit', 'amount', 1000),
            jsonb_build_object('account_id', sender_account_id, 'direction', 'credit', 'amount', 1000)
        )
    );

    SELECT post_transaction(
        'transfer',
        jsonb_build_array(
            jsonb_build_object('account_id', sender_account_id, 'direction', 'debit', 'amount', 505),
            jsonb_build_object('account_id', recipient_account_id, 'direction', 'credit', 'amount', 500),
            jsonb_build_object('account_id', fee_account_id, 'direction', 'credit', 'amount', 5)
        )
    ) INTO test_transaction_id;

    IF NOT EXISTS (
        SELECT 1 FROM transactions WHERE id = test_transaction_id AND type = 'transfer'
    ) OR (
        SELECT COUNT(*) FROM ledger_entries WHERE transaction_id = test_transaction_id
    ) <> 3 THEN
        RAISE EXCEPTION 'TEST FAILED: the three-leg transfer was not recorded';
    END IF;

    FOR account_row IN
        SELECT id, type, cached_balance
        FROM accounts
        WHERE id = ANY(fixture_account_ids)
    LOOP
        SELECT CASE
            WHEN account_row.type IN ('asset', 'expense') THEN
                COALESCE(SUM(amount) FILTER (WHERE direction = 'debit'), 0)
                - COALESCE(SUM(amount) FILTER (WHERE direction = 'credit'), 0)
            ELSE
                COALESCE(SUM(amount) FILTER (WHERE direction = 'credit'), 0)
                - COALESCE(SUM(amount) FILTER (WHERE direction = 'debit'), 0)
        END
        INTO expected_balance
        FROM ledger_entries
        WHERE account_id = account_row.id;

        IF account_row.cached_balance <> expected_balance THEN
            RAISE EXCEPTION
                'TEST FAILED: account % cached balance % differs from ledger balance %',
                account_row.id, account_row.cached_balance, expected_balance;
        END IF;
    END LOOP;
    RAISE NOTICE 'TEST PASSED: Phase 1 transfer posts and cached balances match the ledger';

    -- An unbalanced posting must fail without saving a transaction or entries.
    SELECT COUNT(*) INTO transaction_count_before FROM transactions;
    SELECT COUNT(*) INTO entry_count_before
    FROM ledger_entries WHERE account_id = ANY(fixture_account_ids);
    rejected := FALSE;
    BEGIN
        PERFORM post_transaction(
            'transfer',
            jsonb_build_array(
                jsonb_build_object('account_id', sender_account_id, 'direction', 'debit', 'amount', 505),
                jsonb_build_object('account_id', recipient_account_id, 'direction', 'credit', 'amount', 499),
                jsonb_build_object('account_id', fee_account_id, 'direction', 'credit', 'amount', 5)
            )
        );
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: an unbalanced posting was accepted';
    END IF;
    IF (SELECT COUNT(*) FROM transactions) <> transaction_count_before
       OR (SELECT COUNT(*) FROM ledger_entries WHERE account_id = ANY(fixture_account_ids))
          <> entry_count_before THEN
        RAISE EXCEPTION 'TEST FAILED: the rejected unbalanced posting saved data';
    END IF;
    RAISE NOTICE 'TEST PASSED: an unbalanced posting is rejected with no saved rows';

    -- The sender has 495 left, so a 500-paisa withdrawal must be refused.
    SELECT COUNT(*) INTO transaction_count_before FROM transactions;
    SELECT COUNT(*) INTO entry_count_before
    FROM ledger_entries WHERE account_id = ANY(fixture_account_ids);
    rejected := FALSE;
    BEGIN
        PERFORM post_transaction(
            'withdrawal',
            jsonb_build_array(
                jsonb_build_object('account_id', sender_account_id, 'direction', 'debit', 'amount', 500),
                jsonb_build_object('account_id', bank_account_id, 'direction', 'credit', 'amount', 500)
            )
        );
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: a withdrawal beyond the sender balance was accepted';
    END IF;
    IF (SELECT COUNT(*) FROM transactions) <> transaction_count_before
       OR (SELECT COUNT(*) FROM ledger_entries WHERE account_id = ANY(fixture_account_ids))
          <> entry_count_before
       OR (SELECT cached_balance FROM accounts WHERE id = sender_account_id) <> 495
       OR (SELECT cached_balance FROM accounts WHERE id = bank_account_id) <> 1000 THEN
        RAISE EXCEPTION 'TEST FAILED: the rejected withdrawal changed saved data or balances';
    END IF;
    RAISE NOTICE 'TEST PASSED: an overdrawn withdrawal is rejected and balances stay unchanged';

    -- Use the next ID above the current maximum, which is guaranteed absent.
    SELECT COALESCE(MAX(id), 0) + 1 INTO missing_account_id FROM accounts;
    rejected := FALSE;
    BEGIN
        PERFORM post_transaction(
            'transfer',
            jsonb_build_array(
                jsonb_build_object('account_id', sender_account_id, 'direction', 'debit', 'amount', 1),
                jsonb_build_object('account_id', missing_account_id, 'direction', 'credit', 'amount', 1)
            )
        );
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: a leg for a nonexistent account was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: a leg for a nonexistent account is rejected';

    -- Invalid values must be rejected before a transaction is recorded.
    rejected := FALSE;
    BEGIN
        PERFORM post_transaction(
            'transfer',
            jsonb_build_array(
                jsonb_build_object('account_id', sender_account_id, 'direction', 'debit', 'amount', 0),
                jsonb_build_object('account_id', recipient_account_id, 'direction', 'credit', 'amount', 0)
            )
        );
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: a zero amount was accepted';
    END IF;

    rejected := FALSE;
    BEGIN
        PERFORM post_transaction(
            'transfer',
            jsonb_build_array(
                jsonb_build_object('account_id', sender_account_id, 'direction', 'debit', 'amount', -1),
                jsonb_build_object('account_id', recipient_account_id, 'direction', 'credit', 'amount', -1)
            )
        );
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: a negative amount was accepted';
    END IF;

    rejected := FALSE;
    BEGIN
        PERFORM post_transaction(
            'transfer',
            jsonb_build_array(
                jsonb_build_object('account_id', sender_account_id, 'direction', 'sideways', 'amount', 1),
                jsonb_build_object('account_id', recipient_account_id, 'direction', 'credit', 'amount', 1)
            )
        );
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: an invalid direction was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: zero, negative, and invalid-direction legs are rejected';

    rejected := FALSE;
    BEGIN
        PERFORM post_transaction('transfer', '[]'::jsonb);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: an empty legs list was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: an empty legs list is rejected';

    -- The posting function checks account status while holding the account lock.
    SELECT COUNT(*) INTO transaction_count_before FROM transactions;
    SELECT COUNT(*) INTO entry_count_before
    FROM ledger_entries WHERE account_id = ANY(fixture_account_ids);
    rejected := FALSE;
    BEGIN
        PERFORM post_transaction(
            'transfer',
            jsonb_build_array(
                jsonb_build_object('account_id', recipient_account_id, 'direction', 'debit', 'amount', 1),
                jsonb_build_object('account_id', frozen_account_id, 'direction', 'credit', 'amount', 1)
            )
        );
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: post_transaction accepted a leg on a frozen account';
    END IF;
    IF (SELECT COUNT(*) FROM transactions) <> transaction_count_before
       OR (SELECT COUNT(*) FROM ledger_entries WHERE account_id = ANY(fixture_account_ids))
          <> entry_count_before THEN
        RAISE EXCEPTION 'TEST FAILED: the rejected frozen-account posting saved data';
    END IF;
    RAISE NOTICE 'TEST PASSED: post_transaction rejects a leg on a frozen account';

    -- Insert directly to verify the ledger_entries status trigger itself too.
    rejected := FALSE;
    BEGIN
        INSERT INTO transactions (type)
        VALUES ('transfer')
        RETURNING id INTO test_transaction_id;

        INSERT INTO ledger_entries (transaction_id, account_id, direction, amount)
        VALUES (test_transaction_id, frozen_account_id, 'credit', 1);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: a ledger entry for a frozen account was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: the ledger_entries status trigger rejects a frozen account';

    -- A repeated fee-account leg is combined before the overdraft check. The
    -- debit of 90 alone would overdraw its balance of 5, but the credit of 100
    -- makes the net change +10. The balanced bank debit is the other leg.
    SELECT post_transaction(
        'transfer',
        jsonb_build_array(
            jsonb_build_object('account_id', fee_account_id, 'direction', 'debit', 'amount', 90),
            jsonb_build_object('account_id', fee_account_id, 'direction', 'credit', 'amount', 100),
            jsonb_build_object('account_id', bank_account_id, 'direction', 'debit', 'amount', 10)
        )
    ) INTO test_transaction_id;

    IF (SELECT COUNT(*) FROM ledger_entries
        WHERE transaction_id = test_transaction_id AND account_id = fee_account_id) <> 2
       OR (SELECT cached_balance FROM accounts WHERE id = fee_account_id) <> 15
       OR (SELECT cached_balance FROM accounts WHERE id = bank_account_id) <> 1010 THEN
        RAISE EXCEPTION 'TEST FAILED: duplicate-account legs were not netted before balance update';
    END IF;
    RAISE NOTICE 'TEST PASSED: duplicate fee-account legs are netted before overdraft checking and update';

    -- A self-transfer is a transfer-specific rule. The generic posting function
    -- has no sender/recipient fields, so its rejection is tested with transfer().
    -- The transfer() operation function is not implemented in this phase yet.

    -- Add a valid withdrawal so the final reconciliation covers several posts.
    PERFORM post_transaction(
        'withdrawal',
        jsonb_build_array(
            jsonb_build_object('account_id', recipient_account_id, 'direction', 'debit', 'amount', 100),
            jsonb_build_object('account_id', bank_account_id, 'direction', 'credit', 'amount', 100)
        )
    );

    -- Force the deferred transaction balance triggers now; the outer rollback
    -- still leaves the database unchanged.
    SET CONSTRAINTS ALL IMMEDIATE;

    FOR account_row IN
        SELECT id, type, cached_balance
        FROM accounts
        WHERE id = ANY(fixture_account_ids)
    LOOP
        SELECT CASE
            WHEN account_row.type IN ('asset', 'expense') THEN
                COALESCE(SUM(amount) FILTER (WHERE direction = 'debit'), 0)
                - COALESCE(SUM(amount) FILTER (WHERE direction = 'credit'), 0)
            ELSE
                COALESCE(SUM(amount) FILTER (WHERE direction = 'credit'), 0)
                - COALESCE(SUM(amount) FILTER (WHERE direction = 'debit'), 0)
        END
        INTO expected_balance
        FROM ledger_entries
        WHERE account_id = account_row.id;

        IF account_row.cached_balance <> expected_balance THEN
            RAISE EXCEPTION
                'TEST FAILED: after several postings, account % cached balance % differs from ledger balance %',
                account_row.id, account_row.cached_balance, expected_balance;
        END IF;
    END LOOP;
    RAISE NOTICE 'TEST PASSED: cached balances reconcile after several postings';
END;
$$;

ROLLBACK;
