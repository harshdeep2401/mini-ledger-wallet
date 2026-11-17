-- Run after db/01_schema.sql and db/02_triggers.sql.
-- All fixtures are rolled back so this test leaves the database unchanged.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    sender_account_id BIGINT;
    recipient_account_id BIGINT;
    fee_account_id BIGINT;
    frozen_account_id BIGINT;
    closed_account_id BIGINT;
    balanced_transaction_id BIGINT;
    test_transaction_id BIGINT;
    rejected BOOLEAN;
    transaction_truncate_trigger_exists BOOLEAN;
BEGIN
    INSERT INTO accounts (code, type)
    VALUES ('TRIGGER_TEST_SENDER', 'asset')
    RETURNING id INTO sender_account_id;

    INSERT INTO accounts (code, type)
    VALUES ('TRIGGER_TEST_RECIPIENT', 'asset')
    RETURNING id INTO recipient_account_id;

    INSERT INTO accounts (code, type)
    VALUES ('TRIGGER_TEST_FEE', 'income')
    RETURNING id INTO fee_account_id;

    INSERT INTO accounts (code, type, status)
    VALUES ('TRIGGER_TEST_FROZEN', 'asset', 'frozen')
    RETURNING id INTO frozen_account_id;

    INSERT INTO accounts (code, type, status)
    VALUES ('TRIGGER_TEST_CLOSED', 'asset', 'closed')
    RETURNING id INTO closed_account_id;

    -- A balanced three-leg transfer should pass the deferred balance checks.
    INSERT INTO transactions (type)
    VALUES ('transfer')
    RETURNING id INTO balanced_transaction_id;

    INSERT INTO ledger_entries (transaction_id, account_id, direction, amount)
    VALUES
        (balanced_transaction_id, sender_account_id, 'debit', 105),
        (balanced_transaction_id, recipient_account_id, 'credit', 100),
        (balanced_transaction_id, fee_account_id, 'credit', 5);

    -- Run the same deferred checks that would run at COMMIT, then keep the
    -- outer test transaction rollback-safe.
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'TEST PASSED: balanced three-leg transfer passed deferred checks';
    SET CONSTRAINTS ALL DEFERRED;

    -- An entry added to a previously balanced transaction must be checked too.
    rejected := FALSE;
    BEGIN
        INSERT INTO ledger_entries (transaction_id, account_id, direction, amount)
        VALUES (balanced_transaction_id, sender_account_id, 'debit', 1);
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: an extra unbalanced ledger entry was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: an extra entry on a balanced transaction was rejected';
    SET CONSTRAINTS ALL DEFERRED;

    -- An unbalanced transaction must be rejected by the deferred check.
    rejected := FALSE;
    BEGIN
        INSERT INTO transactions (type)
        VALUES ('transfer')
        RETURNING id INTO test_transaction_id;

        INSERT INTO ledger_entries (transaction_id, account_id, direction, amount)
        VALUES (test_transaction_id, sender_account_id, 'debit', 100);

        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: an unbalanced transaction was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: an unbalanced transaction was rejected';
    SET CONSTRAINTS ALL DEFERRED;

    -- A transaction with no ledger entries must be rejected.
    rejected := FALSE;
    BEGIN
        INSERT INTO transactions (type)
        VALUES ('transfer');

        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: an empty transaction was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: an empty transaction was rejected';
    SET CONSTRAINTS ALL DEFERRED;

    -- Updates and deletes must fail on both append-only tables.
    rejected := FALSE;
    BEGIN
        UPDATE ledger_entries
        SET amount = amount + 1
        WHERE transaction_id = balanced_transaction_id;
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: updating a ledger entry was accepted';
    END IF;

    rejected := FALSE;
    BEGIN
        DELETE FROM ledger_entries
        WHERE transaction_id = balanced_transaction_id;
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: deleting a ledger entry was accepted';
    END IF;

    rejected := FALSE;
    BEGIN
        UPDATE transactions
        SET metadata = '{"changed": true}'::jsonb
        WHERE id = balanced_transaction_id;
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: updating a transaction was accepted';
    END IF;

    rejected := FALSE;
    BEGIN
        DELETE FROM transactions
        WHERE id = balanced_transaction_id;
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: deleting a transaction was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: UPDATE and DELETE are blocked on both tables';

    -- TRUNCATE is statement-level and needs its own triggers on both tables.
    rejected := FALSE;
    BEGIN
        TRUNCATE TABLE ledger_entries;
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: truncating ledger_entries was accepted';
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'ledger.transactions'::regclass
          AND tgname = 'prevent_transaction_truncate'
          AND NOT tgisinternal
          AND tgenabled <> 'D'
    )
    INTO transaction_truncate_trigger_exists;
    IF NOT transaction_truncate_trigger_exists THEN
        RAISE EXCEPTION
            'TEST FAILED: the enabled transactions TRUNCATE trigger is missing';
    END IF;

    rejected := FALSE;
    BEGIN
        TRUNCATE TABLE transactions CASCADE;
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: truncating transactions was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: TRUNCATE is blocked on both tables';

    -- Both frozen and closed accounts must reject postings.
    rejected := FALSE;
    BEGIN
        INSERT INTO transactions (type)
        VALUES ('transfer')
        RETURNING id INTO test_transaction_id;

        INSERT INTO ledger_entries (transaction_id, account_id, direction, amount)
        VALUES (test_transaction_id, frozen_account_id, 'credit', 1);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: posting to a frozen account was accepted';
    END IF;

    rejected := FALSE;
    BEGIN
        INSERT INTO transactions (type)
        VALUES ('transfer')
        RETURNING id INTO test_transaction_id;

        INSERT INTO ledger_entries (transaction_id, account_id, direction, amount)
        VALUES (test_transaction_id, closed_account_id, 'credit', 1);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN
            rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: posting to a closed account was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: frozen and closed accounts reject postings';
END;
$$;

ROLLBACK;
