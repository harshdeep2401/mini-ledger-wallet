-- Run after db/01_schema.sql through db/04_operations.sql.
-- Fixtures, test users, and successful postings are rolled back at the end.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    bank_account_id BIGINT;
    fee_account_id BIGINT;
    sender_user_id BIGINT;
    recipient_user_id BIGINT;
    spent_user_id BIGINT;
    sender_wallet_id BIGINT;
    recipient_wallet_id BIGINT;
    spent_wallet_id BIGINT;
    topup_transaction_id BIGINT;
    transfer_transaction_id BIGINT;
    partial_transfer_id BIGINT;
    partial_refund_id BIGINT;
    spent_transfer_id BIGINT;
    operation_transaction_id BIGINT;
    sender_email TEXT;
    recipient_email TEXT;
    spent_email TEXT;
    sender_balance BIGINT;
    recipient_balance BIGINT;
    bank_balance BIGINT;
    fee_balance BIGINT;
    expected_fee BIGINT;
    transaction_count_before BIGINT;
    entry_count_before BIGINT;
    user_count_before BIGINT;
    rejected BOOLEAN;
    account_row RECORD;
    expected_balance NUMERIC;
    fee_test RECORD;
BEGIN
    -- Tests need the named system accounts. Insert them only when absent;
    -- the outer rollback removes these fixtures if this test created them.
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

    -- D14 fee values, in integer paise, including minimum, maximum and rounding.
    FOR fee_test IN
        SELECT * FROM (VALUES
            (10000::BIGINT, 100::BIGINT),
            (20000::BIGINT, 100::BIGINT),
            (50000::BIGINT, 250::BIGINT),
            (200000::BIGINT, 1000::BIGINT),
            (500000::BIGINT, 1000::BIGINT),
            (33333::BIGINT, 167::BIGINT),
            (33310::BIGINT, 167::BIGINT)
        ) AS expected(amount, fee)
    LOOP
        IF ledger.calculate_fee(fee_test.amount) <> fee_test.fee THEN
            RAISE EXCEPTION
                'TEST FAILED: fee for % paise was %, expected %',
                fee_test.amount,
                ledger.calculate_fee(fee_test.amount),
                fee_test.fee;
        END IF;
    END LOOP;
    RAISE NOTICE 'TEST PASSED: fee minimum, maximum, and rounding values';

    -- Unique test addresses avoid collisions with existing development data.
    sender_email := 'ops-' || md5(clock_timestamp()::TEXT || random()::TEXT) || '@example.test';
    recipient_email := 'ops-' || md5(clock_timestamp()::TEXT || random()::TEXT) || '@example.test';
    spent_email := 'ops-' || md5(clock_timestamp()::TEXT || random()::TEXT) || '@example.test';

    SELECT ledger.create_user_with_wallet('Posting Test Sender', sender_email)
    INTO sender_user_id;
    SELECT ledger.create_user_with_wallet('Posting Test Recipient', recipient_email)
    INTO recipient_user_id;
    SELECT ledger.create_user_with_wallet('Posting Test Spent Wallet', spent_email)
    INTO spent_user_id;

    SELECT id INTO sender_wallet_id
    FROM ledger.accounts WHERE user_id = sender_user_id;
    SELECT id INTO recipient_wallet_id
    FROM ledger.accounts WHERE user_id = recipient_user_id;
    SELECT id INTO spent_wallet_id
    FROM ledger.accounts WHERE user_id = spent_user_id;

    IF sender_user_id IS NULL OR recipient_user_id IS NULL OR spent_user_id IS NULL
       OR sender_wallet_id IS NULL OR recipient_wallet_id IS NULL OR spent_wallet_id IS NULL
       OR (SELECT COUNT(*) FROM ledger.accounts WHERE user_id = sender_user_id) <> 1
       OR (SELECT type FROM ledger.accounts WHERE id = sender_wallet_id) <> 'liability'
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id) <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: user creation did not create linked, zero-balance wallets';
    END IF;
    RAISE NOTICE 'TEST PASSED: create_user_with_wallet creates a linked liability wallet';

    -- A duplicate email must use the project's rule-violation code and leave
    -- the original user and wallet intact, with no partial second user.
    SELECT COUNT(*) INTO user_count_before
    FROM ledger.users WHERE email = sender_email;
    rejected := FALSE;
    BEGIN
        PERFORM ledger.create_user_with_wallet('Duplicate Sender', sender_email);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected OR (SELECT COUNT(*) FROM ledger.users WHERE email = sender_email) <> user_count_before THEN
        RAISE EXCEPTION 'TEST FAILED: duplicate email was not rejected cleanly';
    END IF;
    RAISE NOTICE 'TEST PASSED: duplicate email is rejected with P1001';

    -- Top up ₹1,000 = 100,000 paise: debit Bank and credit the sender wallet.
    SELECT cached_balance INTO bank_balance
    FROM ledger.accounts WHERE id = bank_account_id;
    SELECT ledger.top_up(sender_wallet_id, 100000)
    INTO topup_transaction_id;

    IF (SELECT type FROM ledger.transactions WHERE id = topup_transaction_id) <> 'topup'
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id) <> 100000
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = bank_account_id) <> bank_balance + 100000
       OR (SELECT COUNT(*) FROM ledger.ledger_entries WHERE transaction_id = topup_transaction_id) <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: ₹1,000 top-up balances or ledger entries are incorrect';
    END IF;
    RAISE NOTICE 'TEST PASSED: ₹1,000 top-up credits the wallet and debits Bank';

    -- Transfer ₹500 = 50,000 paise. At 0.5%, its fee is 250 paise (₹2.50).
    expected_fee := ledger.calculate_fee(50000);
    SELECT cached_balance INTO fee_balance
    FROM ledger.accounts WHERE id = fee_account_id;
    SELECT ledger.transfer(sender_wallet_id, recipient_wallet_id, 50000)
    INTO transfer_transaction_id;

    IF expected_fee <> 250
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id) <> 100000 - 50000 - expected_fee
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = recipient_wallet_id) <> 50000
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = fee_account_id) <> fee_balance + expected_fee
       OR (SELECT COUNT(*) FROM ledger.ledger_entries WHERE transaction_id = transfer_transaction_id) <> 3
       OR (SELECT COALESCE(SUM(amount) FILTER (WHERE direction = 'debit'), 0)
           FROM ledger.ledger_entries WHERE transaction_id = transfer_transaction_id)
          <> (SELECT COALESCE(SUM(amount) FILTER (WHERE direction = 'credit'), 0)
              FROM ledger.ledger_entries WHERE transaction_id = transfer_transaction_id) THEN
        RAISE EXCEPTION 'TEST FAILED: transfer legs, fee, or balances are incorrect';
    END IF;
    RAISE NOTICE 'TEST PASSED: ₹500 transfer posts amount plus the calculated fee';

    -- Sender has 49,750 paise. They have enough for a 49,750-paisa transfer
    -- amount but not its additional fee.
    sender_balance := (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id);
    SELECT COUNT(*) INTO transaction_count_before FROM ledger.transactions;
    SELECT COUNT(*) INTO entry_count_before FROM ledger.ledger_entries;
    rejected := FALSE;
    BEGIN
        PERFORM ledger.transfer(sender_wallet_id, recipient_wallet_id, sender_balance);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected
       OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before
       OR (SELECT COUNT(*) FROM ledger.ledger_entries) <> entry_count_before
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id) <> sender_balance THEN
        RAISE EXCEPTION 'TEST FAILED: transfer without funds for the fee was not rejected cleanly';
    END IF;
    RAISE NOTICE 'TEST PASSED: sender cannot transfer the full balance and skip the fee';

    -- A wallet cannot transfer to itself.
    rejected := FALSE;
    BEGIN
        PERFORM ledger.transfer(sender_wallet_id, sender_wallet_id, 1000);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: self-transfer was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: self-transfer is rejected';

    -- Neither endpoint of a transfer may be a system account.
    rejected := FALSE;
    BEGIN
        PERFORM ledger.transfer(sender_wallet_id, bank_account_id, 1000);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: transfer to a system account was accepted';
    END IF;

    rejected := FALSE;
    BEGIN
        PERFORM ledger.transfer(bank_account_id, recipient_wallet_id, 1000);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: transfer from a system account was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: transfers to and from system accounts are rejected';

    -- Withdraw ₹200 = 20,000 paise from the sender.
    sender_balance := (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id);
    bank_balance := (SELECT cached_balance FROM ledger.accounts WHERE id = bank_account_id);
    SELECT ledger.withdraw(sender_wallet_id, 20000) INTO operation_transaction_id;
    IF (SELECT type FROM ledger.transactions WHERE id = operation_transaction_id) <> 'withdrawal'
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id) <> sender_balance - 20000
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = bank_account_id) <> bank_balance - 20000 THEN
        RAISE EXCEPTION 'TEST FAILED: ₹200 withdrawal balances are incorrect';
    END IF;
    RAISE NOTICE 'TEST PASSED: ₹200 withdrawal debits the wallet and credits Bank';

    -- An overdrawn withdrawal fails and changes neither balances nor history.
    sender_balance := (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id);
    bank_balance := (SELECT cached_balance FROM ledger.accounts WHERE id = bank_account_id);
    SELECT COUNT(*) INTO transaction_count_before FROM ledger.transactions;
    SELECT COUNT(*) INTO entry_count_before FROM ledger.ledger_entries;
    rejected := FALSE;
    BEGIN
        PERFORM ledger.withdraw(sender_wallet_id, sender_balance + 1);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected
       OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before
       OR (SELECT COUNT(*) FROM ledger.ledger_entries) <> entry_count_before
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id) <> sender_balance
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = bank_account_id) <> bank_balance THEN
        RAISE EXCEPTION 'TEST FAILED: overdrawn withdrawal was not rejected without changes';
    END IF;
    RAISE NOTICE 'TEST PASSED: overdrawn withdrawal is rejected without changing balances';

    -- Full refund: only the recipient amount returns; the transfer fee stays
    -- credited to FEE_INCOME.
    fee_balance := (SELECT cached_balance FROM ledger.accounts WHERE id = fee_account_id);
    sender_balance := (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id);
    SELECT ledger.refund(transfer_transaction_id, 50000)
    INTO operation_transaction_id;
    IF (SELECT type FROM ledger.transactions WHERE id = operation_transaction_id) <> 'refund'
       OR (SELECT reverses_transaction_id FROM ledger.transactions WHERE id = operation_transaction_id)
          <> transfer_transaction_id
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = recipient_wallet_id) <> 0
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = sender_wallet_id) <> sender_balance + 50000
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = fee_account_id) <> fee_balance THEN
        RAISE EXCEPTION 'TEST FAILED: full refund did not return only the recipient amount';
    END IF;
    RAISE NOTICE 'TEST PASSED: full refund returns the transfer amount but not its fee';

    -- Partial refund: refund 6,000 of a 10,000-paisa transfer, then try to
    -- refund 5,000 more (which would exceed the original recipient credit).
    SELECT ledger.transfer(sender_wallet_id, recipient_wallet_id, 10000)
    INTO partial_transfer_id;
    SELECT ledger.refund(partial_transfer_id, 6000)
    INTO partial_refund_id;
    IF (SELECT reverses_transaction_id FROM ledger.transactions WHERE id = partial_refund_id)
       <> partial_transfer_id
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = recipient_wallet_id) <> 4000 THEN
        RAISE EXCEPTION 'TEST FAILED: first partial refund was not recorded correctly';
    END IF;

    SELECT COUNT(*) INTO transaction_count_before FROM ledger.transactions;
    SELECT COUNT(*) INTO entry_count_before FROM ledger.ledger_entries;
    rejected := FALSE;
    BEGIN
        PERFORM ledger.refund(partial_transfer_id, 5000);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected
       OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before
       OR (SELECT COUNT(*) FROM ledger.ledger_entries) <> entry_count_before
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = recipient_wallet_id) <> 4000 THEN
        RAISE EXCEPTION 'TEST FAILED: refund above the remaining cap was not rejected cleanly';
    END IF;
    RAISE NOTICE 'TEST PASSED: partial refund succeeds and the cap rejects an excess refund';

    -- A refund cannot itself be refunded, and a top-up is not refundable.
    rejected := FALSE;
    BEGIN
        PERFORM ledger.refund(partial_refund_id, 1);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: refund of a refund was accepted';
    END IF;

    rejected := FALSE;
    BEGIN
        PERFORM ledger.refund(topup_transaction_id, 1);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: refund of a top-up was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: refunds of refunds and top-ups are rejected';

    -- If the recipient has spent the full amount, the normal posting overdraft
    -- check rejects the refund and preserves the balances and transaction log.
    SELECT ledger.transfer(sender_wallet_id, spent_wallet_id, 10000)
    INTO spent_transfer_id;
    PERFORM ledger.withdraw(spent_wallet_id, 10000);
    SELECT COUNT(*) INTO transaction_count_before FROM ledger.transactions;
    SELECT COUNT(*) INTO entry_count_before FROM ledger.ledger_entries;
    rejected := FALSE;
    BEGIN
        PERFORM ledger.refund(spent_transfer_id, 10000);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected
       OR (SELECT COUNT(*) FROM ledger.transactions) <> transaction_count_before
       OR (SELECT COUNT(*) FROM ledger.ledger_entries) <> entry_count_before
       OR (SELECT cached_balance FROM ledger.accounts WHERE id = spent_wallet_id) <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: refund after recipient spent the funds was not rejected cleanly';
    END IF;
    RAISE NOTICE 'TEST PASSED: refund fails when the recipient has spent the funds';

    -- A frozen wallet cannot send or receive. The posting function's status
    -- check refuses both calls before any ledger rows are written.
    PERFORM ledger.freeze_account(recipient_wallet_id);
    rejected := FALSE;
    BEGIN
        PERFORM ledger.transfer(sender_wallet_id, recipient_wallet_id, 100);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: transfer to a frozen wallet was accepted';
    END IF;

    rejected := FALSE;
    BEGIN
        PERFORM ledger.transfer(recipient_wallet_id, sender_wallet_id, 100);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: transfer from a frozen wallet was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: frozen wallets cannot send or receive transfers';

    -- Unfreeze, then confirm a transfer can post again.
    IF ledger.unfreeze_account(recipient_wallet_id) <> recipient_wallet_id THEN
        RAISE EXCEPTION 'TEST FAILED: unfreeze_account returned the wrong account ID';
    END IF;
    PERFORM ledger.transfer(sender_wallet_id, recipient_wallet_id, 100);
    RAISE NOTICE 'TEST PASSED: unfreezing restores the wallet transfer path';

    -- Illegal transitions: freezing an already frozen wallet and unfreezing an
    -- active wallet are both rejected. Restore the fixture to active afterward.
    PERFORM ledger.freeze_account(recipient_wallet_id);
    rejected := FALSE;
    BEGIN
        PERFORM ledger.freeze_account(recipient_wallet_id);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: freezing an already frozen wallet was accepted';
    END IF;
    PERFORM ledger.unfreeze_account(recipient_wallet_id);

    rejected := FALSE;
    BEGIN
        PERFORM ledger.unfreeze_account(sender_wallet_id);
    EXCEPTION
        WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: unfreezing an active wallet was accepted';
    END IF;
    RAISE NOTICE 'TEST PASSED: illegal freeze and unfreeze transitions are rejected';

    -- Force deferred balance triggers now; then reconcile each account's
    -- cached balance against the independently summed ledger entries.
    SET CONSTRAINTS ALL IMMEDIATE;

    FOR account_row IN
        SELECT id, type, cached_balance
        FROM ledger.accounts
        WHERE id = ANY(ARRAY[
            bank_account_id,
            fee_account_id,
            sender_wallet_id,
            recipient_wallet_id,
            spent_wallet_id
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
    RAISE NOTICE 'TEST PASSED: cached balances reconcile after all operation scenarios';
END;
$$;

ROLLBACK;
