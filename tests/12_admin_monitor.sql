-- Extended features: the admin monitor functions from db/11_admin_monitor.sql
-- (notify trigger, recent_transactions, ledger_stats, transaction_refunds).
-- Everything rolls back at the end. NOTIFY is only delivered on commit, so this
-- test checks that the trigger is installed and enabled rather than listening.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    v_suffix TEXT := md5(clock_timestamp()::TEXT || random()::TEXT);
    v_sender_user BIGINT;
    v_recipient_user BIGINT;
    v_sender_wallet BIGINT;
    v_recipient_wallet BIGINT;
    v_before_id BIGINT;
    v_transfer_id BIGINT;
    v_refund_id BIGINT;
    v_count INTEGER;
    v_rejected BOOLEAN;
    v_row RECORD;
    v_stats_before RECORD;
    v_stats_after RECORD;
    v_function TEXT;
BEGIN
    SELECT * INTO v_stats_before FROM ledger.ledger_stats();

    v_sender_user := ledger.create_user_with_wallet('Monitor Sender', 'monitor-sender-' || v_suffix || '@example.test');
    v_recipient_user := ledger.create_user_with_wallet('Monitor Recipient', 'monitor-recipient-' || v_suffix || '@example.test');
    SELECT id INTO v_sender_wallet FROM ledger.accounts WHERE user_id = v_sender_user;
    SELECT id INTO v_recipient_wallet FROM ledger.accounts WHERE user_id = v_recipient_user;

    SELECT COALESCE(max(id), 0) INTO v_before_id FROM ledger.transactions;

    PERFORM ledger.top_up(v_sender_wallet, 100000, 'monitor-fund-' || v_suffix);
    v_transfer_id := ledger.transfer(v_sender_wallet, v_recipient_wallet, 40000, 'monitor-pay-' || v_suffix);
    v_refund_id := ledger.refund(v_transfer_id, 15000, 'monitor-refund-' || v_suffix);

    -- the notify trigger exists and is enabled
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'ledger.transactions'::regclass
          AND tgname = 'notify_transaction_created'
          AND NOT tgisinternal
          AND tgenabled <> 'D'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: the enabled notify_transaction_created trigger is missing';
    END IF;

    -- recent_transactions: only rows after the given id, newest first, with summary columns
    SELECT count(*) INTO v_count FROM ledger.recent_transactions(200, v_before_id);
    IF v_count <> 3 THEN
        RAISE EXCEPTION 'TEST FAILED: recent_transactions after id returned % rows, expected 3', v_count;
    END IF;

    SELECT * INTO v_row FROM ledger.recent_transactions(200, v_before_id) LIMIT 1;
    IF v_row.transaction_id <> v_refund_id THEN
        RAISE EXCEPTION 'TEST FAILED: the newest transaction was not listed first';
    END IF;

    SELECT * INTO v_row FROM ledger.recent_transactions(200, v_before_id) WHERE transaction_id = v_transfer_id;
    IF v_row.from_label <> 'Monitor Sender' OR v_row.to_label <> 'Monitor Recipient'
       OR v_row.amount <> 40000 OR v_row.fee <> 200 THEN
        RAISE EXCEPTION 'TEST FAILED: transfer summary was % -> %, amount %, fee %',
            v_row.from_label, v_row.to_label, v_row.amount, v_row.fee;
    END IF;

    FOREACH v_count IN ARRAY ARRAY[0, 201] LOOP
        v_rejected := FALSE;
        BEGIN
            PERFORM * FROM ledger.recent_transactions(v_count, NULL);
        EXCEPTION WHEN SQLSTATE 'P1001' THEN
            v_rejected := TRUE;
        END;
        IF NOT v_rejected THEN
            RAISE EXCEPTION 'TEST FAILED: recent_transactions accepted a limit of %', v_count;
        END IF;
    END LOOP;

    -- ledger_stats: counts move by what we posted, and the books still balance
    SELECT * INTO v_stats_after FROM ledger.ledger_stats();
    IF v_stats_after.transaction_count - v_stats_before.transaction_count <> 3
       OR v_stats_after.transfers - v_stats_before.transfers <> 1
       OR v_stats_after.refunds - v_stats_before.refunds <> 1
       OR v_stats_after.wallet_count - v_stats_before.wallet_count <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: ledger_stats moved by % transactions, % transfers, % refunds, % wallets (expected 3, 1, 1, 2)',
            v_stats_after.transaction_count - v_stats_before.transaction_count,
            v_stats_after.transfers - v_stats_before.transfers,
            v_stats_after.refunds - v_stats_before.refunds,
            v_stats_after.wallet_count - v_stats_before.wallet_count;
    END IF;
    IF v_stats_after.fee_income - v_stats_before.fee_income <> 200 THEN
        RAISE EXCEPTION 'TEST FAILED: fee income moved by %, expected 200',
            v_stats_after.fee_income - v_stats_before.fee_income;
    END IF;
    IF v_stats_after.books_difference <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: BANK - wallets - FEE_INCOME = %, expected 0', v_stats_after.books_difference;
    END IF;

    -- transaction_refunds: the refund and what is left; nothing for a non-transfer
    SELECT * INTO v_row FROM ledger.transaction_refunds(v_transfer_id);
    IF v_row.refund_transaction_id <> v_refund_id OR v_row.amount <> 15000 OR v_row.remaining_after <> 25000 THEN
        RAISE EXCEPTION 'TEST FAILED: refund row was #% amount % remaining %',
            v_row.refund_transaction_id, v_row.amount, v_row.remaining_after;
    END IF;

    SELECT count(*) INTO v_count FROM ledger.transaction_refunds(v_refund_id);
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: a refund itself reported refunds';
    END IF;

    -- grants: admin and reporting only
    FOREACH v_function IN ARRAY ARRAY[
        'ledger.recent_transactions(integer,bigint)', 'ledger.ledger_stats()', 'ledger.transaction_refunds(bigint)'
    ] LOOP
        IF NOT has_function_privilege('ledger_admin', v_function, 'EXECUTE')
           OR NOT has_function_privilege('ledger_reporting', v_function, 'EXECUTE') THEN
            RAISE EXCEPTION 'TEST FAILED: admin/reporting cannot execute %', v_function;
        END IF;
        IF has_function_privilege('ledger_app', v_function, 'EXECUTE')
           OR has_function_privilege('ledger_web', v_function, 'EXECUTE')
           OR has_function_privilege('public', v_function, 'EXECUTE') THEN
            RAISE EXCEPTION 'TEST FAILED: an app role or PUBLIC can execute %', v_function;
        END IF;
    END LOOP;

    -- and they work as ledger_admin, which has no table access
    SET LOCAL ROLE ledger_admin;
    SELECT count(*) INTO v_count FROM ledger.recent_transactions(200, v_before_id);
    RESET ROLE;
    IF v_count <> 3 THEN
        RAISE EXCEPTION 'TEST FAILED: recent_transactions returned % rows for ledger_admin', v_count;
    END IF;

    RAISE NOTICE 'TEST PASSED: notify trigger, recent_transactions, ledger_stats, transaction_refunds';
END;
$$;

ROLLBACK;
