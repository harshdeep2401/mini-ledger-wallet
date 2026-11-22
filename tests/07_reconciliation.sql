-- Run after db/07_reconciliation.sql. Intentional corruption is rolled back.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    bank_account_id BIGINT;
    sender_user_id BIGINT;
    recipient_user_id BIGINT;
    empty_user_id BIGINT;
    sender_wallet_id BIGINT;
    recipient_wallet_id BIGINT;
    empty_wallet_id BIGINT;
    topup_transaction_id BIGINT;
    transfer_transaction_id BIGINT;
    refund_transaction_id BIGINT;
    invalid_transaction_id BIGINT;
    expected_sender_balance BIGINT;
    expected_recipient_balance BIGINT;
    account_problem_count BIGINT;
    issue_row RECORD;
    email_suffix TEXT := md5(clock_timestamp()::TEXT || random()::TEXT);
    rejected_or_skipped BOOLEAN := FALSE;
BEGIN
    SELECT id INTO bank_account_id FROM ledger.accounts WHERE code = 'BANK';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEST FAILED: BANK system account is missing';
    END IF;

    -- Seeds are deliberately separate from db:reset, but may already have been
    -- run. Check that the starting state is healthy without requiring it empty.
    IF (SELECT COUNT(*) FROM ledger.accounts WHERE code IN ('BANK', 'FEE_INCOME')) <> 2
       OR NOT ledger.reconciliation_summary()
       OR EXISTS (SELECT 1 FROM ledger.reconciliation_issues()) THEN
        RAISE EXCEPTION 'TEST FAILED: the starting ledger is missing system accounts or is unhealthy';
    END IF;
    RAISE NOTICE 'TEST PASSED: starting ledger is healthy with both system accounts';

    SELECT ledger.create_user_with_wallet('Reconcile Sender', 'reconcile-sender-' || email_suffix || '@example.test')
    INTO sender_user_id;
    SELECT ledger.create_user_with_wallet('Reconcile Recipient', 'reconcile-recipient-' || email_suffix || '@example.test')
    INTO recipient_user_id;
    SELECT ledger.create_user_with_wallet('Reconcile Empty', 'reconcile-empty-' || email_suffix || '@example.test')
    INTO empty_user_id;

    SELECT id INTO sender_wallet_id FROM ledger.accounts WHERE user_id = sender_user_id;
    SELECT id INTO recipient_wallet_id FROM ledger.accounts WHERE user_id = recipient_user_id;
    SELECT id INTO empty_wallet_id FROM ledger.accounts WHERE user_id = empty_user_id;

    -- A wallet with no entries must still be included in the balance check as 0.
    IF ledger.get_balance(empty_wallet_id) <> 0
       OR EXISTS (
           SELECT 1 FROM ledger.reconciliation_issues()
           WHERE check_name = 'account_cached_balance_matches_entries'
             AND account_id = empty_wallet_id
       ) THEN
        RAISE EXCEPTION 'TEST FAILED: an empty wallet was omitted or miscomputed';
    END IF;
    RAISE NOTICE 'TEST PASSED: a wallet with no entries reconciles to zero';

    -- Build a valid mix of top-up, transfer, withdrawal and partial refund.
    topup_transaction_id := ledger.top_up(sender_wallet_id, 100000, 'reconcile-topup');
    transfer_transaction_id := ledger.transfer(sender_wallet_id, recipient_wallet_id, 50000, 'reconcile-transfer');
    PERFORM ledger.withdraw(sender_wallet_id, 10000, 'reconcile-withdrawal');
    refund_transaction_id := ledger.refund(transfer_transaction_id, 10000, 'reconcile-refund');

    IF NOT ledger.reconciliation_summary()
       OR EXISTS (SELECT 1 FROM ledger.reconciliation_issues()) THEN
        RAISE EXCEPTION 'TEST FAILED: valid operations produced reconciliation issues';
    END IF;
    RAISE NOTICE 'TEST PASSED: top-up, transfer, withdrawal and refund reconcile';

    -- Deliberately add balanced legs to a refund transaction so the refund
    -- total exceeds the original recipient amount while debits still equal credits.
    BEGIN
        INSERT INTO ledger.ledger_entries (transaction_id, account_id, direction, amount)
        VALUES
            (refund_transaction_id, recipient_wallet_id, 'debit', 40001),
            (refund_transaction_id, sender_wallet_id, 'credit', 40001);
        SET CONSTRAINTS ALL IMMEDIATE;

        IF NOT EXISTS (
            SELECT 1 FROM ledger.reconciliation_issues()
            WHERE check_name = 'refund_within_transfer_amount'
              AND transaction_id = transfer_transaction_id
              AND expected = '50000'
              AND actual = '50001'
              AND difference = 1
        ) THEN
            RAISE EXCEPTION 'TEST FAILED: over-cap refund was not reported';
        END IF;

        RAISE EXCEPTION USING ERRCODE = 'P7R02', MESSAGE = 'roll back deliberate refund-cap corruption';
    EXCEPTION WHEN SQLSTATE 'P7R02' THEN
        NULL;
    END;
    RAISE NOTICE 'TEST PASSED: refund cap is audited even when the transaction balances';

    -- Make a balanced manual withdrawal from the empty wallet. The ledger
    -- remains balanced, but its recomputed balance is below zero.
    BEGIN
        INSERT INTO ledger.transactions (type)
        VALUES ('withdrawal')
        RETURNING id INTO invalid_transaction_id;
        INSERT INTO ledger.ledger_entries (transaction_id, account_id, direction, amount)
        VALUES
            (invalid_transaction_id, empty_wallet_id, 'debit', 1),
            (invalid_transaction_id, bank_account_id, 'credit', 1);
        SET CONSTRAINTS ALL IMMEDIATE;

        IF NOT EXISTS (
            SELECT 1 FROM ledger.reconciliation_issues()
            WHERE check_name = 'account_balance_nonnegative'
              AND account_id = empty_wallet_id
              AND expected = '0'
              AND actual = '-1'
              AND difference = -1
        ) THEN
            RAISE EXCEPTION 'TEST FAILED: negative account balance was not reported';
        END IF;

        RAISE EXCEPTION USING ERRCODE = 'P7R03', MESSAGE = 'roll back deliberate overdraft';
    EXCEPTION WHEN SQLSTATE 'P7R03' THEN
        NULL;
    END;
    RAISE NOTICE 'TEST PASSED: negative recomputed balance is audited independently';

    -- The idempotency key row is immutable. Temporarily disable the transaction
    -- append-only trigger inside a subtransaction to prove mismatches are found.
    SET CONSTRAINTS ALL IMMEDIATE;
    rejected_or_skipped := FALSE;
    BEGIN
        EXECUTE 'ALTER TABLE ledger.transactions DISABLE TRIGGER prevent_transaction_changes';
        UPDATE ledger.transactions
        SET idempotency_key = 'reconciliation-intentionally-wrong'
        WHERE id = topup_transaction_id;
        EXECUTE 'ALTER TABLE ledger.transactions ENABLE TRIGGER prevent_transaction_changes';

        IF NOT EXISTS (
            SELECT 1 FROM ledger.reconciliation_issues()
            WHERE check_name = 'idempotency_key_matches_transaction'
              AND transaction_id = topup_transaction_id
              AND expected = 'reconcile-topup'
              AND actual = 'reconciliation-intentionally-wrong'
        ) THEN
            RAISE EXCEPTION 'TEST FAILED: idempotency key mismatch was not reported';
        END IF;

        RAISE EXCEPTION USING ERRCODE = 'P7R04', MESSAGE = 'roll back deliberate idempotency corruption';
    EXCEPTION
        WHEN SQLSTATE 'P7R04' THEN NULL;
        WHEN insufficient_privilege THEN rejected_or_skipped := TRUE;
    END;
    IF rejected_or_skipped THEN
        RAISE NOTICE 'TEST SKIPPED: this database role cannot disable the transaction append-only trigger';
    ELSE
        RAISE NOTICE 'TEST PASSED: idempotency key mismatch is detected';
    END IF;

    -- Corrupt one cached balance and require exactly its one detailed issue.
    SELECT cached_balance INTO expected_sender_balance
    FROM ledger.accounts WHERE id = sender_wallet_id;
    UPDATE ledger.accounts SET cached_balance = cached_balance + 7
    WHERE id = sender_wallet_id;
    SELECT COUNT(*) INTO account_problem_count FROM ledger.reconciliation_issues();
    SELECT * INTO issue_row FROM ledger.reconciliation_issues();
    IF account_problem_count <> 1
       OR issue_row.check_name <> 'account_cached_balance_matches_entries'
       OR issue_row.account_id <> sender_wallet_id
       OR issue_row.expected <> expected_sender_balance::TEXT
       OR issue_row.actual <> (expected_sender_balance + 7)::TEXT
       OR issue_row.difference <> 7 THEN
        RAISE EXCEPTION 'TEST FAILED: one corrupted balance did not report exactly the expected issue';
    END IF;
    IF ledger.reconciliation_summary() THEN
        RAISE EXCEPTION 'TEST FAILED: summary reported healthy while an account was corrupted';
    END IF;
    UPDATE ledger.accounts SET cached_balance = expected_sender_balance
    WHERE id = sender_wallet_id;
    RAISE NOTICE 'TEST PASSED: one corrupted account reports the right expected, actual and difference';

    -- Two corruptions must produce exactly those two account issues.
    SELECT cached_balance INTO expected_sender_balance
    FROM ledger.accounts WHERE id = sender_wallet_id;
    SELECT cached_balance INTO expected_recipient_balance
    FROM ledger.accounts WHERE id = recipient_wallet_id;
    UPDATE ledger.accounts SET cached_balance = cached_balance + 11
    WHERE id = sender_wallet_id;
    UPDATE ledger.accounts SET cached_balance = cached_balance + 22
    WHERE id = recipient_wallet_id;
    SELECT COUNT(*) INTO account_problem_count FROM ledger.reconciliation_issues();
    IF account_problem_count <> 2
       OR EXISTS (
           SELECT 1 FROM ledger.reconciliation_issues()
           WHERE check_name <> 'account_cached_balance_matches_entries'
              OR account_id NOT IN (sender_wallet_id, recipient_wallet_id)
       )
       OR (SELECT COUNT(*) FROM ledger.reconciliation_issues()
           WHERE account_id = sender_wallet_id
             AND expected = expected_sender_balance::TEXT
             AND actual = (expected_sender_balance + 11)::TEXT
             AND difference = 11) <> 1
       OR (SELECT COUNT(*) FROM ledger.reconciliation_issues()
           WHERE account_id = recipient_wallet_id
             AND expected = expected_recipient_balance::TEXT
             AND actual = (expected_recipient_balance + 22)::TEXT
             AND difference = 22) <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: two corrupted balances did not report exactly those accounts';
    END IF;
    UPDATE ledger.accounts SET cached_balance = expected_sender_balance
    WHERE id = sender_wallet_id;
    UPDATE ledger.accounts SET cached_balance = expected_recipient_balance
    WHERE id = recipient_wallet_id;
    RAISE NOTICE 'TEST PASSED: two corrupted accounts report exactly two matching issues';

    -- A one-paisa error is detected with no tolerance.
    UPDATE ledger.accounts SET cached_balance = cached_balance + 1
    WHERE id = sender_wallet_id;
    SELECT * INTO issue_row FROM ledger.reconciliation_issues();
    IF issue_row.check_name <> 'account_cached_balance_matches_entries'
       OR issue_row.account_id <> sender_wallet_id
       OR issue_row.difference <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: a one-paisa cached-balance error was not caught';
    END IF;
    UPDATE ledger.accounts SET cached_balance = expected_sender_balance
    WHERE id = sender_wallet_id;
    RAISE NOTICE 'TEST PASSED: a one-paisa balance error is caught';

    -- Flush all legitimate deferred checks before creating the deliberately
    -- malformed extra leg. A nested block makes that corruption and the DDL
    -- transactional; raising the marker rolls back to a healthy ledger.
    SET CONSTRAINTS ALL IMMEDIATE;
    rejected_or_skipped := FALSE;
    BEGIN
        EXECUTE 'ALTER TABLE ledger.ledger_entries DISABLE TRIGGER balance_ledger_check';
        INSERT INTO ledger.ledger_entries (transaction_id, account_id, direction, amount)
        VALUES (topup_transaction_id, bank_account_id, 'debit', 1);
        EXECUTE 'ALTER TABLE ledger.ledger_entries ENABLE TRIGGER balance_ledger_check';

        IF NOT EXISTS (
            SELECT 1 FROM ledger.reconciliation_issues()
            WHERE check_name = 'global_debits_equal_credits'
              AND difference = -1
        ) OR NOT EXISTS (
            SELECT 1 FROM ledger.reconciliation_issues()
            WHERE check_name = 'transaction_debits_equal_credits'
              AND transaction_id = topup_transaction_id
              AND difference = -1
        ) THEN
            RAISE EXCEPTION 'TEST FAILED: global or per-transaction imbalance was not reported';
        END IF;

        RAISE EXCEPTION USING ERRCODE = 'P7R01', MESSAGE = 'roll back deliberate ledger corruption';
    EXCEPTION
        WHEN SQLSTATE 'P7R01' THEN
            NULL;
        WHEN insufficient_privilege THEN
            rejected_or_skipped := TRUE;
    END;

    IF rejected_or_skipped THEN
        RAISE NOTICE 'TEST SKIPPED: this database role cannot disable the deferred balance trigger';
    ELSE
        RAISE NOTICE 'TEST PASSED: global debit-credit mismatch is detected';
    END IF;

    IF NOT ledger.reconciliation_summary()
       OR EXISTS (SELECT 1 FROM ledger.reconciliation_issues()) THEN
        RAISE EXCEPTION 'TEST FAILED: ledger did not reconcile after the corruption was rolled back';
    END IF;
    RAISE NOTICE 'TEST PASSED: reconciliation is healthy again after corruption rollback';
END;
$$;

ROLLBACK;
