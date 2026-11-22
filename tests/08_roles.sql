-- Run after db/08_roles.sql. All test users, postings and the temporary
-- default-privilege probe function are rolled back/dropped at the end.
-- Re-running db/08_roles.sql itself is a separate manual check; older schema
-- files are not all idempotent, so do not use db:apply for that check.
BEGIN;

CREATE TEMP TABLE role_test_ids (
    sender_wallet_id BIGINT NOT NULL,
    recipient_wallet_id BIGINT NOT NULL,
    app_email TEXT NOT NULL
);
GRANT SELECT ON pg_temp.role_test_ids TO ledger_app, ledger_reporting, ledger_admin;
DO $$
DECLARE
    temp_schema_name TEXT;
BEGIN
    SELECT nspname INTO temp_schema_name
    FROM pg_catalog.pg_namespace
    WHERE oid = pg_catalog.pg_my_temp_schema();
    EXECUTE pg_catalog.format(
        'GRANT USAGE ON SCHEMA %I TO ledger_app, ledger_reporting, ledger_admin',
        temp_schema_name
    );
END;
$$;

DO $$
DECLARE
    sender_user_id BIGINT;
    recipient_user_id BIGINT;
    sender_wallet_id BIGINT;
    recipient_wallet_id BIGINT;
    app_email TEXT := 'roles-app-created-' || pg_catalog.md5(pg_catalog.clock_timestamp()::TEXT || pg_catalog.random()::TEXT) || '@example.test';
BEGIN
    SELECT ledger.create_user_with_wallet(
        'Role Test Sender', 'roles-sender-' || pg_catalog.md5(pg_catalog.clock_timestamp()::TEXT || pg_catalog.random()::TEXT) || '@example.test'
    ) INTO sender_user_id;
    SELECT ledger.create_user_with_wallet(
        'Role Test Recipient', 'roles-recipient-' || pg_catalog.md5(pg_catalog.clock_timestamp()::TEXT || pg_catalog.random()::TEXT) || '@example.test'
    ) INTO recipient_user_id;

    SELECT id INTO sender_wallet_id FROM ledger.accounts WHERE user_id = sender_user_id;
    SELECT id INTO recipient_wallet_id FROM ledger.accounts WHERE user_id = recipient_user_id;
    INSERT INTO pg_temp.role_test_ids VALUES (sender_wallet_id, recipient_wallet_id, app_email);

    IF sender_wallet_id IS NULL OR recipient_wallet_id IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: role test fixture wallets were not created';
    END IF;
END;
$$;

SET LOCAL ROLE ledger_owner;
CREATE FUNCTION ledger.roles_test_future_function()
RETURNS INTEGER LANGUAGE sql AS 'SELECT 1';
RESET ROLE;
CREATE FUNCTION ledger.roles_test_migration_function()
RETURNS INTEGER LANGUAGE sql AS 'SELECT 1';
SET LOCAL ROLE ledger_app;

DO $$
DECLARE
    sender_wallet_id BIGINT;
    recipient_wallet_id BIGINT;
    app_email TEXT;
    table_names TEXT[] := ARRAY[
        'ledger_entries', 'transactions', 'accounts', 'users', 'idempotency_keys'
    ];
    update_columns TEXT[] := ARRAY['amount', 'metadata', 'code', 'name', 'created_at'];
    denied_calls TEXT[] := ARRAY[
        'SELECT ledger.post_transaction(''topup''::ledger.transaction_type, ''[]''::jsonb)',
        'SELECT ledger.check_idempotency(''roles-internal-check'', pg_catalog.decode(pg_catalog.repeat(''00'', 32), ''hex''))',
        'SELECT ledger.record_idempotency(''roles-internal-key'', pg_catalog.decode(pg_catalog.repeat(''00'', 32), ''hex''), 1)',
        'SELECT ledger.idempotency_fingerprint(''top_up'', ''{}''::jsonb)',
        'SELECT ledger.assert_transaction_accounts_active(1)',
        'SELECT ledger.balance_check()',
        'SELECT ledger.prevent_changes()',
        'SELECT ledger.status_guard()'
    ];
    helper_names TEXT[] := ARRAY[
        'post_transaction', 'check_idempotency', 'record_idempotency',
        'idempotency_fingerprint', 'assert_transaction_accounts_active',
        'balance_check', 'prevent_changes', 'status_guard'
    ];
    table_name TEXT;
    call_sql TEXT;
    error_message TEXT;
    index_no INTEGER;
    denied BOOLEAN;
    user_id_returned BIGINT;
    transfer_id BIGINT;
    history_count BIGINT;
BEGIN
    SELECT role_test_ids.sender_wallet_id, role_test_ids.recipient_wallet_id, role_test_ids.app_email
    INTO sender_wallet_id, recipient_wallet_id, app_email
    FROM pg_temp.role_test_ids AS role_test_ids;

    IF sender_wallet_id IS NULL OR recipient_wallet_id IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: role test fixture wallets were not created';
    END IF;

    -- App cannot reach ledger tables directly, even for a zero-row write.
    FOR index_no IN 1..pg_catalog.array_length(table_names, 1) LOOP
        table_name := table_names[index_no];

        denied := FALSE;
        BEGIN
            EXECUTE pg_catalog.format('INSERT INTO ledger.%I DEFAULT VALUES', table_name);
        EXCEPTION WHEN insufficient_privilege THEN
            GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
            denied := error_message LIKE 'permission denied for table %'
                AND pg_catalog.strpos(error_message, table_name) > 0;
        END;
        IF NOT denied THEN
            RAISE EXCEPTION 'TEST FAILED: ledger_app can INSERT into %', table_name;
        END IF;

        denied := FALSE;
        BEGIN
            EXECUTE pg_catalog.format(
                'UPDATE ledger.%I SET %I = %I WHERE FALSE',
                table_name, update_columns[index_no], update_columns[index_no]
            );
        EXCEPTION WHEN insufficient_privilege THEN
            GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
            denied := error_message LIKE 'permission denied for table %'
                AND pg_catalog.strpos(error_message, table_name) > 0;
        END;
        IF NOT denied THEN
            RAISE EXCEPTION 'TEST FAILED: ledger_app can UPDATE %', table_name;
        END IF;

        denied := FALSE;
        BEGIN
            EXECUTE pg_catalog.format('DELETE FROM ledger.%I WHERE FALSE', table_name);
        EXCEPTION WHEN insufficient_privilege THEN
            GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
            denied := error_message LIKE 'permission denied for table %'
                AND pg_catalog.strpos(error_message, table_name) > 0;
        END;
        IF NOT denied THEN
            RAISE EXCEPTION 'TEST FAILED: ledger_app can DELETE from %', table_name;
        END IF;

        denied := FALSE;
        BEGIN
            EXECUTE pg_catalog.format('TRUNCATE TABLE ledger.%I', table_name);
        EXCEPTION WHEN insufficient_privilege THEN
            GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
            denied := error_message LIKE 'permission denied for table %'
                AND pg_catalog.strpos(error_message, table_name) > 0;
        END;
        IF NOT denied THEN
            RAISE EXCEPTION 'TEST FAILED: ledger_app can TRUNCATE %', table_name;
        END IF;
    END LOOP;
    RAISE NOTICE 'TEST PASSED: app is denied INSERT, UPDATE, DELETE and TRUNCATE on every ledger table';

    denied := FALSE;
    BEGIN
        PERFORM 1 FROM ledger.accounts;
    EXCEPTION WHEN insufficient_privilege THEN denied := TRUE;
    END;
    IF NOT denied THEN
        RAISE EXCEPTION 'TEST FAILED: ledger_app can SELECT directly from accounts';
    END IF;
    RAISE NOTICE 'TEST PASSED: app cannot SELECT ledger tables directly';

    index_no := 1;
    FOREACH call_sql IN ARRAY denied_calls LOOP
        denied := FALSE;
        BEGIN
            EXECUTE call_sql;
        EXCEPTION WHEN insufficient_privilege THEN
            GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
            denied := error_message LIKE 'permission denied for function %'
                AND pg_catalog.strpos(error_message, helper_names[index_no]) > 0;
        END;
        IF NOT denied THEN
            RAISE EXCEPTION 'TEST FAILED: ledger_app can execute internal helper: %', call_sql;
        END IF;
        index_no := index_no + 1;
    END LOOP;

    denied := FALSE;
    BEGIN
        PERFORM ledger.freeze_account(sender_wallet_id);
    EXCEPTION WHEN insufficient_privilege THEN denied := TRUE;
    END;
    IF NOT denied THEN
        RAISE EXCEPTION 'TEST FAILED: ledger_app can freeze an account';
    END IF;
    denied := FALSE;
    BEGIN
        PERFORM ledger.unfreeze_account(sender_wallet_id);
    EXCEPTION WHEN insufficient_privilege THEN denied := TRUE;
    END;
    IF NOT denied THEN
        RAISE EXCEPTION 'TEST FAILED: ledger_app can unfreeze an account';
    END IF;
    denied := FALSE;
    BEGIN
        PERFORM ledger.reconciliation_summary();
    EXCEPTION WHEN insufficient_privilege THEN denied := TRUE;
    END;
    IF NOT denied THEN
        RAISE EXCEPTION 'TEST FAILED: ledger_app can run reconciliation';
    END IF;
    RAISE NOTICE 'TEST PASSED: app cannot call admin or reporting functions';

    denied := FALSE;
    BEGIN
        PERFORM ledger.roles_test_future_function();
    EXCEPTION WHEN insufficient_privilege THEN denied := TRUE;
    END;
    IF NOT denied THEN
        RAISE EXCEPTION 'TEST FAILED: a new function was executable without a grant';
    END IF;
    denied := FALSE;
    BEGIN
        PERFORM ledger.roles_test_migration_function();
    EXCEPTION WHEN insufficient_privilege THEN denied := TRUE;
    END;
    IF NOT denied THEN
        RAISE EXCEPTION 'TEST FAILED: a function created by the migration login was executable by app without a grant';
    END IF;
    RAISE NOTICE 'TEST PASSED: owner and migration-login functions are closed to app until explicitly granted';

    denied := FALSE;
    BEGIN
        EXECUTE 'ALTER TABLE ledger.ledger_entries DISABLE TRIGGER block_inactive_account_postings';
    EXCEPTION WHEN insufficient_privilege THEN denied := TRUE;
    END;
    IF NOT denied THEN
        RAISE EXCEPTION 'TEST FAILED: ledger_app can disable a ledger trigger';
    END IF;
    RAISE NOTICE 'TEST PASSED: app cannot disable ledger triggers';

    -- Prove the permitted app path works and actually changes ledger state.
    user_id_returned := ledger.create_user_with_wallet(
        'Created Through App', app_email
    );
    PERFORM ledger.top_up(sender_wallet_id, 100000, 'roles-app-topup');
    transfer_id := ledger.transfer(sender_wallet_id, recipient_wallet_id, 20000, 'roles-app-transfer');
    PERFORM ledger.withdraw(sender_wallet_id, 1000, 'roles-app-withdrawal');
    PERFORM ledger.refund(transfer_id, 5000, 'roles-app-refund');

    IF user_id_returned IS NULL
       OR ledger.get_balance(sender_wallet_id) <> 83900
       OR ledger.get_balance(recipient_wallet_id) <> 15000
       OR ledger.calculate_fee(20000) <> 100 THEN
        RAISE EXCEPTION 'TEST FAILED: allowed app functions did not create the user or expected balances';
    END IF;
    SELECT COUNT(*) INTO history_count
    FROM ledger.get_history(sender_wallet_id, NULL, NULL, 20);
    IF history_count <> 4 THEN
        RAISE EXCEPTION 'TEST FAILED: app history function returned % rows, expected 4', history_count;
    END IF;
    RAISE NOTICE 'TEST PASSED: app can create users, move money and read balance/history';
END;
$$;

RESET ROLE;

DO $$
DECLARE
    app_email TEXT;
BEGIN
    SELECT role_test_ids.app_email INTO app_email
    FROM pg_temp.role_test_ids AS role_test_ids;
    IF (SELECT COUNT(*) FROM ledger.users WHERE email = app_email) <> 1
       OR NOT EXISTS (
           SELECT 1 FROM ledger.accounts
           WHERE user_id = (SELECT id FROM ledger.users WHERE email = app_email)
       ) THEN
        RAISE EXCEPTION 'TEST FAILED: app SECURITY DEFINER create_user did not persist its user and wallet';
    END IF;
END;
$$;

SET LOCAL ROLE ledger_reporting;
DO $$
DECLARE
    sender_wallet_id BIGINT;
    recipient_wallet_id BIGINT;
    rejected BOOLEAN := FALSE;
    history_count BIGINT;
BEGIN
    SELECT role_test_ids.sender_wallet_id, role_test_ids.recipient_wallet_id
    INTO sender_wallet_id, recipient_wallet_id
    FROM pg_temp.role_test_ids AS role_test_ids;

    IF NOT ledger.reconciliation_summary()
       OR EXISTS (SELECT 1 FROM ledger.reconciliation_issues())
       OR ledger.get_balance(sender_wallet_id) <> 83900 THEN
        RAISE EXCEPTION 'TEST FAILED: reporting read or reconciliation functions failed';
    END IF;
    SELECT COUNT(*) INTO history_count
    FROM ledger.get_history(recipient_wallet_id, NULL, NULL, 20);
    IF history_count <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: reporting history returned %, expected 2 rows', history_count;
    END IF;

    rejected := FALSE;
    BEGIN
        PERFORM ledger.top_up(sender_wallet_id, 1, 'roles-reporting-forbidden-topup');
    EXCEPTION WHEN insufficient_privilege THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: reporting role can call a money-moving function';
    END IF;

    rejected := FALSE;
    BEGIN
        PERFORM 1 FROM ledger.accounts;
    EXCEPTION WHEN insufficient_privilege THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: reporting role can SELECT directly from accounts';
    END IF;
    RAISE NOTICE 'TEST PASSED: reporting can read and reconcile, but has no table or write access';
END;
$$;

RESET ROLE;
SET LOCAL ROLE ledger_admin;
DO $$
DECLARE
    recipient_wallet_id BIGINT;
    rejected BOOLEAN := FALSE;
BEGIN
    SELECT role_test_ids.recipient_wallet_id INTO recipient_wallet_id
    FROM pg_temp.role_test_ids AS role_test_ids;

    PERFORM ledger.freeze_account(recipient_wallet_id);
    PERFORM ledger.unfreeze_account(recipient_wallet_id);
    IF NOT ledger.reconciliation_summary()
       OR EXISTS (SELECT 1 FROM ledger.reconciliation_issues()) THEN
        RAISE EXCEPTION 'TEST FAILED: admin freeze/unfreeze or reconciliation path failed';
    END IF;

    rejected := FALSE;
    BEGIN
        PERFORM ledger.top_up(recipient_wallet_id, 1, 'roles-admin-forbidden-topup');
    EXCEPTION WHEN insufficient_privilege THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: admin role can call a money-moving function';
    END IF;

    rejected := FALSE;
    BEGIN
        PERFORM 1 FROM ledger.accounts;
    EXCEPTION WHEN insufficient_privilege THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: admin role can SELECT directly from accounts';
    END IF;
    RAISE NOTICE 'TEST PASSED: admin can freeze/unfreeze and reconcile without table access';
END;
$$;

RESET ROLE;
SET LOCAL ROLE ledger_owner;
DROP FUNCTION ledger.roles_test_future_function();
RESET ROLE;
DROP FUNCTION ledger.roles_test_migration_function();
RESET ROLE;

ROLLBACK;
