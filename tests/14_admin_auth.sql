-- Admin log-in from db/13_admin_auth.sql. Everything rolls back.
-- Checks: invite-only sign-up (single use), log in / lockout / log out, every admin_*
-- function refuses a missing, wrong or USER token, and ledger_web reaches no admin table.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    v_suffix TEXT := md5(clock_timestamp()::TEXT || random()::TEXT);
    v_invite TEXT := 'test-invite-' || v_suffix;
    v_email TEXT := 'admin-' || v_suffix || '@example.test';
    v_admin_token TEXT;
    v_user_token TEXT;
    v_wallet BIGINT;
    v_error TEXT;
    v_rejected BOOLEAN;
    v_count INTEGER;
    v_call TEXT;
    v_i INTEGER;
BEGIN
    -- the owner creates an invite; a wallet user exists for the "wrong kind of token" checks
    PERFORM ledger.create_admin_invite(v_invite);

    SET LOCAL ROLE ledger_web;
    SELECT token INTO v_user_token FROM ledger.sign_up('Admin Test User', 'admin-test-user-' || v_suffix || '@example.test', 'password-u');
    SELECT account_id INTO v_wallet FROM ledger.my_wallet(v_user_token);

    -- sign-up needs a valid, unused invite
    v_rejected := FALSE;
    BEGIN
        PERFORM * FROM ledger.admin_sign_up('Nope', 'nope-' || v_suffix || '@example.test', 'password-n', 'wrong-invite');
    EXCEPTION WHEN SQLSTATE 'P1001' THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST FAILED: admin sign-up accepted a wrong invite code';
    END IF;

    SELECT token INTO v_admin_token FROM ledger.admin_sign_up('Test Admin', upper(v_email), 'password-admin', v_invite);
    IF length(v_admin_token) <> 64 THEN
        RAISE EXCEPTION 'TEST FAILED: admin sign-up did not return a token';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM * FROM ledger.admin_sign_up('Again', 'again-' || v_suffix || '@example.test', 'password-a', v_invite);
    EXCEPTION WHEN SQLSTATE 'P1001' THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST FAILED: an invite code was used twice';
    END IF;

    -- the admin token works on admin functions
    IF (SELECT email FROM ledger.admin_me(v_admin_token)) <> v_email THEN
        RAISE EXCEPTION 'TEST FAILED: admin_me did not return the lower-cased email';
    END IF;
    SELECT count(*) INTO v_count FROM ledger.admin_wallets(v_admin_token, 'Admin Test User', 5);
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: admin_wallets found % rows, expected 1', v_count;
    END IF;
    PERFORM ledger.admin_freeze(v_admin_token, v_wallet);
    IF (SELECT status FROM ledger.my_wallet(v_user_token)) <> 'frozen' THEN
        RAISE EXCEPTION 'TEST FAILED: admin_freeze did not freeze the wallet';
    END IF;
    PERFORM ledger.admin_unfreeze(v_admin_token, v_wallet);
    PERFORM * FROM ledger.admin_stats(v_admin_token);
    PERFORM * FROM ledger.admin_feed(v_admin_token, 5, NULL);

    -- no token, a bogus token, or a USER token: every admin function says P1002
    FOREACH v_call IN ARRAY ARRAY[
        'SELECT * FROM ledger.admin_me(%L)',
        'SELECT * FROM ledger.admin_stats(%L)',
        'SELECT * FROM ledger.admin_feed(%L, 5, NULL)',
        'SELECT * FROM ledger.admin_transaction(%L, 1)',
        'SELECT * FROM ledger.admin_transaction_refunds(%L, 1)',
        'SELECT * FROM ledger.admin_wallets(%L, NULL, 5)',
        'SELECT ledger.admin_freeze(%L, 1)',
        'SELECT ledger.admin_unfreeze(%L, 1)',
        'SELECT ledger.admin_reconciliation(%L)',
        'SELECT * FROM ledger.admin_reconciliation_issues(%L)'
    ] LOOP
        FOREACH v_error IN ARRAY ARRAY['', 'not-a-token', v_user_token] LOOP
            v_rejected := FALSE;
            BEGIN
                EXECUTE format(v_call, v_error);
            EXCEPTION WHEN SQLSTATE 'P1002' THEN
                v_rejected := TRUE;
            END;
            IF NOT v_rejected THEN
                RAISE EXCEPTION 'TEST FAILED: % accepted a non-admin token', v_call;
            END IF;
        END LOOP;
    END LOOP;

    -- and an admin token is not a user token
    v_rejected := FALSE;
    BEGIN
        PERFORM * FROM ledger.my_wallet(v_admin_token);
    EXCEPTION WHEN SQLSTATE 'P1002' THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST FAILED: an admin token was accepted as a wallet user';
    END IF;

    -- ledger_web cannot reach the admin tables or the internal helpers
    FOREACH v_call IN ARRAY ARRAY[
        'SELECT * FROM ledger.admins',
        'SELECT * FROM ledger.admin_sessions',
        'SELECT * FROM ledger.admin_invites',
        format('SELECT ledger.create_admin_invite(%L)', 'sneaky-invite-code'),
        format('SELECT ledger.create_admin(%L, %L, %L)', 'X', 'x@example.test', 'password-x'),
        format('SELECT ledger.admin_authenticate(%L)', v_admin_token),
        'SELECT ledger.freeze_account(1)',
        'SELECT ledger.reconciliation_summary()'
    ] LOOP
        v_rejected := FALSE;
        BEGIN
            EXECUTE v_call;
        EXCEPTION WHEN insufficient_privilege THEN
            v_rejected := TRUE;
        END;
        IF NOT v_rejected THEN
            RAISE EXCEPTION 'TEST FAILED: ledger_web was allowed: %', v_call;
        END IF;
    END LOOP;

    -- log in, lockout after 5 wrong passwords, log out
    SELECT error INTO v_error FROM ledger.admin_log_in(v_email, 'password-admin');
    IF v_error IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: correct admin log-in returned %', v_error;
    END IF;
    FOR v_i IN 1..5 LOOP
        PERFORM * FROM ledger.admin_log_in(v_email, 'wrong-password');
    END LOOP;
    SELECT error INTO v_error FROM ledger.admin_log_in(v_email, 'password-admin');
    IF v_error IS NULL OR v_error NOT LIKE 'too many failed attempts%' THEN
        RAISE EXCEPTION 'TEST FAILED: admin email was not locked (got %)', v_error;
    END IF;

    PERFORM ledger.admin_log_out(v_admin_token);
    v_rejected := FALSE;
    BEGIN
        PERFORM * FROM ledger.admin_me(v_admin_token);
    EXCEPTION WHEN SQLSTATE 'P1002' THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST FAILED: a logged-out admin token still worked';
    END IF;

    RESET ROLE;

    -- storage: hashes only
    IF EXISTS (SELECT 1 FROM ledger.admins WHERE email = v_email AND password_hash NOT LIKE '$2a$%')
       OR EXISTS (SELECT 1 FROM ledger.admin_invites WHERE code_hash = convert_to(v_invite, 'UTF8')) THEN
        RAISE EXCEPTION 'TEST FAILED: an admin password or invite code is stored readable';
    END IF;

    RAISE NOTICE 'TEST PASSED: admin invite sign-up, log-in, lockout, log-out and token checks on every admin function';
END;
$$;

ROLLBACK;
