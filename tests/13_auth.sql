-- Extended features: simulated login from db/12_auth.sql. Everything rolls back.
-- Checks: sign up / log in / log out, hashed storage, lockout, the "own wallet only"
-- rules, and that ledger_web can reach nothing but the session-token functions.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    v_suffix TEXT := md5(clock_timestamp()::TEXT || random()::TEXT);
    v_email_a TEXT := 'auth-a-' || v_suffix || '@example.test';
    v_email_b TEXT := 'auth-b-' || v_suffix || '@example.test';
    v_token_a TEXT;
    v_token_b TEXT;
    v_wallet_a BIGINT;
    v_wallet_b BIGINT;
    v_transfer_id BIGINT;
    v_balance BIGINT;
    v_count INTEGER;
    v_error TEXT;
    v_rejected BOOLEAN;
    v_row RECORD;
    v_call TEXT;
    v_i INTEGER;
BEGIN
    SET LOCAL ROLE ledger_web;

    -- sign up returns a 64-character token; a short password is refused
    SELECT token INTO v_token_a FROM ledger.sign_up('Auth A', v_email_a, 'password-a');
    SELECT token INTO v_token_b FROM ledger.sign_up('Auth B', v_email_b, 'password-b');
    IF length(v_token_a) <> 64 OR v_token_a = v_token_b THEN
        RAISE EXCEPTION 'TEST FAILED: sign_up did not return distinct 64-character tokens';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM * FROM ledger.sign_up('Auth C', 'auth-c-' || v_suffix || '@example.test', 'short');
    EXCEPTION WHEN SQLSTATE 'P1001' THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST FAILED: sign_up accepted a 5-character password';
    END IF;

    SELECT account_id INTO v_wallet_a FROM ledger.my_wallet(v_token_a);
    SELECT account_id INTO v_wallet_b FROM ledger.my_wallet(v_token_b);

    -- money moves only from the token's own wallet
    PERFORM ledger.my_top_up(v_token_a, 100000, 'auth-fund-' || v_suffix);
    v_transfer_id := ledger.my_transfer(v_token_a, v_wallet_b, 20000, 'auth-pay-' || v_suffix);
    SELECT balance INTO v_balance FROM ledger.my_wallet(v_token_a);
    IF v_balance <> 100000 - 20000 - 100 THEN
        RAISE EXCEPTION 'TEST FAILED: sender balance was %, expected 79900', v_balance;
    END IF;

    -- only the receiver can refund
    v_rejected := FALSE;
    BEGIN
        PERFORM ledger.my_refund(v_token_a, v_transfer_id, 100, 'auth-bad-refund-' || v_suffix);
    EXCEPTION WHEN SQLSTATE 'P1001' THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST FAILED: the sender was allowed to refund their own payment';
    END IF;
    PERFORM ledger.my_refund(v_token_b, v_transfer_id, 5000, 'auth-refund-' || v_suffix);

    -- history is the caller's own; recipients hide balances and leave out the caller
    SELECT count(*) INTO v_count FROM ledger.my_history(v_token_b);
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST FAILED: B history had % rows, expected 2', v_count;
    END IF;

    SELECT * INTO v_row FROM ledger.find_recipients(v_token_a, 'Auth B', 5);
    IF v_row.account_id <> v_wallet_b OR v_row.masked_email NOT LIKE 'a***@%' THEN
        RAISE EXCEPTION 'TEST FAILED: recipient search returned % / %', v_row.account_id, v_row.masked_email;
    END IF;
    IF EXISTS (SELECT 1 FROM ledger.find_recipients(v_token_a, 'Auth A', 20) WHERE account_id = v_wallet_a) THEN
        RAISE EXCEPTION 'TEST FAILED: find_recipients listed the caller';
    END IF;

    -- a bad token is refused with P1002
    v_rejected := FALSE;
    BEGIN
        PERFORM * FROM ledger.my_wallet('not-a-token');
    EXCEPTION WHEN SQLSTATE 'P1002' THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST FAILED: my_wallet accepted an unknown token';
    END IF;

    -- ledger_web cannot call the unscoped functions or read the tables
    FOREACH v_call IN ARRAY ARRAY[
        format('SELECT ledger.transfer(%s, %s, 1, %L)', v_wallet_b, v_wallet_a, 'auth-direct-' || v_suffix),
        format('SELECT ledger.get_balance(%s)', v_wallet_b),
        format('SELECT * FROM ledger.get_history(%s)', v_wallet_b),
        'SELECT * FROM ledger.list_wallets(NULL, 5)',
        format('SELECT ledger.authenticate(%L)', v_token_a),
        format('SELECT ledger.set_password(1, %L)', 'password-x'),
        'SELECT * FROM ledger.sessions',
        'SELECT * FROM ledger.user_credentials',
        'SELECT * FROM ledger.accounts'
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

    -- log in: email is case-insensitive; wrong password and unknown email look the same
    SELECT error INTO v_error FROM ledger.log_in(upper(v_email_a), 'password-a');
    IF v_error IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: correct log-in returned error %', v_error;
    END IF;
    SELECT error INTO v_error FROM ledger.log_in('nobody-' || v_suffix || '@example.test', 'password-a');
    IF v_error IS DISTINCT FROM 'invalid email or password' THEN
        RAISE EXCEPTION 'TEST FAILED: unknown email returned %', v_error;
    END IF;

    -- five wrong passwords lock the email, even for the right password
    FOR v_i IN 1..5 LOOP
        SELECT error INTO v_error FROM ledger.log_in(v_email_a, 'wrong-password');
        IF v_error IS DISTINCT FROM 'invalid email or password' THEN
            RAISE EXCEPTION 'TEST FAILED: wrong password % returned %', v_i, v_error;
        END IF;
    END LOOP;
    SELECT error INTO v_error FROM ledger.log_in(v_email_a, 'password-a');
    IF v_error IS NULL OR v_error NOT LIKE 'too many failed attempts%' THEN
        RAISE EXCEPTION 'TEST FAILED: the email was not locked after 5 failures (got %)', v_error;
    END IF;

    -- log out ends the session
    PERFORM ledger.log_out(v_token_b);
    v_rejected := FALSE;
    BEGIN
        PERFORM * FROM ledger.my_wallet(v_token_b);
    EXCEPTION WHEN SQLSTATE 'P1002' THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST FAILED: a logged-out token still worked';
    END IF;

    RESET ROLE;

    -- storage: no plain password or token anywhere
    IF EXISTS (
        SELECT 1 FROM ledger.user_credentials AS c
        JOIN ledger.users AS u ON u.id = c.user_id
        WHERE u.email = v_email_a
          AND (c.password_hash = 'password-a' OR c.password_hash NOT LIKE '$2a$%')
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: the password is not stored as a bcrypt hash';
    END IF;
    IF EXISTS (SELECT 1 FROM ledger.sessions WHERE token_hash = convert_to(v_token_a, 'UTF8'))
       OR NOT EXISTS (SELECT 1 FROM ledger.sessions WHERE token_hash = sha256(convert_to(v_token_a, 'UTF8'))) THEN
        RAISE EXCEPTION 'TEST FAILED: the session token is not stored as a SHA-256 hash';
    END IF;

    RAISE NOTICE 'TEST PASSED: sign up, log in, lockout, log out, own-wallet rules and ledger_web limits';
END;
$$;

ROLLBACK;
