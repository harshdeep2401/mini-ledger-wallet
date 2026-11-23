-- Phase 12: the read functions behind the API and the demo console
-- (list_wallets, get_transaction, account_overview). Everything rolls back at the end.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    v_suffix TEXT := md5(clock_timestamp()::TEXT || random()::TEXT);
    v_older_user BIGINT;
    v_newer_user BIGINT;
    v_older_wallet BIGINT;
    v_newer_wallet BIGINT;
    v_transfer_id BIGINT;
    v_found BIGINT;
    v_count INTEGER;
    v_debits BIGINT;
    v_credits BIGINT;
    v_rejected BOOLEAN;
    v_row RECORD;
    v_function TEXT;
BEGIN
    SELECT ledger.create_user_with_wallet('Read Fn Older', 'readfn-older-' || v_suffix || '@example.test') INTO v_older_user;
    SELECT ledger.create_user_with_wallet('Read Fn Newer', 'readfn-newer-' || v_suffix || '@example.test') INTO v_newer_user;
    SELECT id INTO v_older_wallet FROM ledger.accounts WHERE user_id = v_older_user;
    SELECT id INTO v_newer_wallet FROM ledger.accounts WHERE user_id = v_newer_user;
    PERFORM ledger.top_up(v_older_wallet, 100000, 'readfn-fund-' || v_suffix);
    v_transfer_id := ledger.transfer(v_older_wallet, v_newer_wallet, 50000, 'readfn-pay-' || v_suffix);

    -- list_wallets: newest first, searchable, user wallets only
    SELECT account_id INTO v_found FROM ledger.list_wallets(NULL, 1);
    IF v_found IS DISTINCT FROM v_newer_wallet THEN
        RAISE EXCEPTION 'TEST FAILED: the newest wallet was not listed first';
    END IF;

    SELECT count(*) INTO v_count FROM ledger.list_wallets(v_suffix, 10);
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: searching by email found % wallets, expected 2', v_count;
    END IF;

    IF EXISTS (SELECT 1 FROM ledger.list_wallets('bank', 50) WHERE name ILIKE 'bank') THEN
        RAISE EXCEPTION 'TEST FAILED: a system account appeared in the wallet list';
    END IF;

    FOREACH v_count IN ARRAY ARRAY[0, 201] LOOP
        v_rejected := FALSE;
        BEGIN
            PERFORM * FROM ledger.list_wallets(NULL, v_count);
        EXCEPTION WHEN SQLSTATE 'P1001' THEN
            v_rejected := TRUE;
        END;
        IF NOT v_rejected THEN
            RAISE EXCEPTION 'TEST FAILED: list_wallets accepted a limit of %', v_count;
        END IF;
    END LOOP;

    -- get_transaction: three legs that balance, and a clear error for a missing id
    SELECT count(*), COALESCE(sum(amount) FILTER (WHERE direction = 'debit'), 0),
           COALESCE(sum(amount) FILTER (WHERE direction = 'credit'), 0)
    INTO v_count, v_debits, v_credits
    FROM ledger.get_transaction(v_transfer_id);
    IF v_count <> 3 OR v_debits <> 50250 OR v_credits <> 50250 THEN
        RAISE EXCEPTION 'TEST FAILED: transfer legs were % legs, debits %, credits %', v_count, v_debits, v_credits;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM ledger.get_transaction(v_transfer_id) WHERE account_label = 'FEE_INCOME' AND amount = 250) THEN
        RAISE EXCEPTION 'TEST FAILED: the fee leg to FEE_INCOME is missing';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM * FROM ledger.get_transaction(-1);
    EXCEPTION WHEN SQLSTATE 'P1001' THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST FAILED: get_transaction accepted a missing transaction';
    END IF;

    -- account_overview: chosen wallets plus the system accounts, balances match
    SELECT * INTO v_row FROM ledger.account_overview(ARRAY[v_older_wallet, v_newer_wallet]) WHERE account_id = v_newer_wallet;
    IF v_row.balance <> 50000 OR v_row.label <> 'Read Fn Newer' THEN
        RAISE EXCEPTION 'TEST FAILED: recipient overview was % / %', v_row.label, v_row.balance;
    END IF;

    SELECT count(*) INTO v_count FROM ledger.account_overview(ARRAY[v_older_wallet]) WHERE code IN ('BANK', 'FEE_INCOME');
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: BANK and FEE_INCOME were not always included';
    END IF;

    SELECT count(*) INTO v_count FROM ledger.account_overview(NULL) WHERE code IS NULL;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: account_overview(NULL) returned user wallets';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM * FROM ledger.account_overview(ARRAY(SELECT generate_series(1, 51)::BIGINT));
    EXCEPTION WHEN SQLSTATE 'P1001' THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST FAILED: account_overview accepted 51 ids';
    END IF;

    -- grants: the app roles may call them, PUBLIC may not
    FOREACH v_function IN ARRAY ARRAY[
        'ledger.list_wallets(text,integer)', 'ledger.get_transaction(bigint)', 'ledger.account_overview(bigint[])'
    ] LOOP
        IF NOT has_function_privilege('ledger_app', v_function, 'EXECUTE') THEN
            RAISE EXCEPTION 'TEST FAILED: ledger_app cannot execute %', v_function;
        END IF;
        IF has_function_privilege('public', v_function, 'EXECUTE') THEN
            RAISE EXCEPTION 'TEST FAILED: PUBLIC can execute %', v_function;
        END IF;
    END LOOP;

    -- and they really work as the app role, which has no table access
    SET LOCAL ROLE ledger_app;
    SELECT count(*) INTO v_count FROM ledger.get_transaction(v_transfer_id);
    SELECT count(*) INTO v_found FROM ledger.list_wallets(v_suffix, 10);
    RESET ROLE;
    IF v_count <> 3 OR v_found <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: the read functions returned the wrong rows for ledger_app';
    END IF;

    RAISE NOTICE 'TEST PASSED: list_wallets, get_transaction and account_overview';
END;
$$;

ROLLBACK;
