-- INVARIANTS (simulated login; no real identity or money):
--   * Passwords are stored only as bcrypt hashes (pgcrypto crypt()). Session tokens are
--     stored only as SHA-256 hashes; the plain token is returned once, at log-in.
--   * The browser-facing login, ledger_web, can call ONLY the functions in this file.
--     Every one of them takes a session token, and the database itself works out which
--     wallet the token belongs to. A user cannot name another user's wallet as the source
--     of money or read another user's balance or history.
--   * Failed log-ins are counted, and 5 in a row lock the email for 5 minutes. log_in()
--     reports failure as a returned value, not an exception, because an exception would
--     roll back the failure count it just recorded.
--   * ledger_app keeps its older, unscoped functions for trusted internal tools (demo
--     console, traffic simulator, tests). It is not used by the browser-facing routes.

-- pgcrypto in its own schema, so a development reset of "ledger" does not drop it.
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
GRANT USAGE ON SCHEMA extensions TO ledger_owner;
-- db/08_roles.sql closes new functions to PUBLIC by default, which includes pgcrypto's.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO ledger_owner;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ledger_web') THEN
        CREATE ROLE ledger_web LOGIN;
    END IF;
END;
$$;
ALTER ROLE ledger_web LOGIN NOCREATEDB NOCREATEROLE;

-- The migration login may SET ROLE ledger_web in tests, like the other capability roles.
DO $$
BEGIN
    IF SESSION_USER <> 'ledger_web' THEN
        EXECUTE format('GRANT ledger_web TO %I', SESSION_USER);
    END IF;
END;
$$;

SET ROLE ledger_owner;

-- 1. Tables -------------------------------------------------------------------------

-- One login per user. Kept out of "users" so the profile table stays free of secrets.
CREATE TABLE IF NOT EXISTS ledger.user_credentials (
    user_id BIGINT PRIMARY KEY REFERENCES ledger.users(id) ON DELETE RESTRICT,
    password_hash TEXT NOT NULL,
    failed_attempts INTEGER NOT NULL DEFAULT 0,
    locked_until TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT user_credentials_failed_attempts_check CHECK (failed_attempts >= 0)
);

CREATE TABLE IF NOT EXISTS ledger.sessions (
    token_hash BYTEA PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES ledger.users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    CONSTRAINT sessions_expiry_check CHECK (expires_at > created_at)
);
CREATE INDEX IF NOT EXISTS sessions_user_id_idx ON ledger.sessions (user_id);

REVOKE ALL ON ledger.user_credentials, ledger.sessions FROM PUBLIC;

-- 2. Internal helpers (never granted) ------------------------------------------------

CREATE OR REPLACE FUNCTION ledger.hash_token(p_token TEXT)
RETURNS BYTEA
LANGUAGE sql
IMMUTABLE
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
    SELECT pg_catalog.sha256(pg_catalog.convert_to(COALESCE(p_token, ''), 'UTF8'));
$$;

-- Sets (or replaces) a user's password. Used by sign_up() and the demo login seed.
CREATE OR REPLACE FUNCTION ledger.set_password(p_user_id BIGINT, p_password TEXT)
RETURNS VOID
LANGUAGE plpgsql
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    -- bcrypt reads at most 72 bytes, so longer passwords would be silently cut.
    IF p_password IS NULL OR length(p_password) < 8 OR octet_length(p_password) > 72 THEN
        RAISE EXCEPTION 'password must be 8 to 72 characters'
            USING ERRCODE = 'P1001';
    END IF;

    INSERT INTO ledger.user_credentials (user_id, password_hash)
    VALUES (p_user_id, extensions.crypt(p_password, extensions.gen_salt('bf', 8)))
    ON CONFLICT (user_id) DO UPDATE
        SET password_hash = EXCLUDED.password_hash,
            failed_attempts = 0,
            locked_until = NULL,
            updated_at = CURRENT_TIMESTAMP;
END;
$$;

CREATE OR REPLACE FUNCTION ledger.start_session(p_user_id BIGINT)
RETURNS TABLE (token TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_token TEXT := encode(extensions.gen_random_bytes(32), 'hex');
    v_expires TIMESTAMPTZ := CURRENT_TIMESTAMP + INTERVAL '8 hours';
BEGIN
    INSERT INTO ledger.sessions (token_hash, user_id, expires_at)
    VALUES (ledger.hash_token(v_token), p_user_id, v_expires);
    RETURN QUERY SELECT v_token, v_expires;
END;
$$;

-- The user behind a token, or SQLSTATE P1002 (the server answers 401).
CREATE OR REPLACE FUNCTION ledger.authenticate(p_token TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_user_id BIGINT;
BEGIN
    SELECT s.user_id
    INTO v_user_id
    FROM ledger.sessions AS s
    JOIN ledger.users AS u ON u.id = s.user_id
    WHERE s.token_hash = ledger.hash_token(p_token)
      AND s.revoked_at IS NULL
      AND s.expires_at > CURRENT_TIMESTAMP
      AND u.is_active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'not logged in, or the session has expired'
            USING ERRCODE = 'P1002';
    END IF;
    RETURN v_user_id;
END;
$$;

-- The wallet of the user behind a token.
-- (plpgsql with a variable, so the token is checked exactly once.)
CREATE OR REPLACE FUNCTION ledger.my_wallet_id(p_token TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_user_id BIGINT := ledger.authenticate(p_token);
BEGIN
    RETURN (SELECT a.id FROM ledger.accounts AS a WHERE a.user_id = v_user_id);
END;
$$;

-- 3. Sign up, log in, log out (granted to ledger_web) --------------------------------

CREATE OR REPLACE FUNCTION ledger.sign_up(p_name TEXT, p_email TEXT, p_password TEXT)
RETURNS TABLE (token TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_user_id BIGINT;
BEGIN
    -- Check the password first so a bad one does not leave a user behind
    -- (it would be rolled back anyway; this just gives the clearer message).
    IF p_password IS NULL OR length(p_password) < 8 OR octet_length(p_password) > 72 THEN
        RAISE EXCEPTION 'password must be 8 to 72 characters'
            USING ERRCODE = 'P1001';
    END IF;

    v_user_id := ledger.create_user_with_wallet(p_name, p_email);
    PERFORM ledger.set_password(v_user_id, p_password);
    RETURN QUERY SELECT * FROM ledger.start_session(v_user_id);
END;
$$;

CREATE OR REPLACE FUNCTION ledger.log_in(p_email TEXT, p_password TEXT)
RETURNS TABLE (token TEXT, expires_at TIMESTAMPTZ, error TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_user_id BIGINT;
    v_hash TEXT;
    v_locked_until TIMESTAMPTZ;
    v_failed INTEGER;
BEGIN
    SELECT c.user_id, c.password_hash, c.locked_until, c.failed_attempts
    INTO v_user_id, v_hash, v_locked_until, v_failed
    FROM ledger.users AS u
    JOIN ledger.user_credentials AS c ON c.user_id = u.id
    WHERE lower(u.email) = lower(btrim(p_email))
      AND u.is_active
    FOR UPDATE OF c;

    IF NOT FOUND THEN
        -- Same message and similar time as a wrong password, so the answer does
        -- not reveal which emails have accounts.
        PERFORM extensions.crypt(COALESCE(p_password, ''), extensions.gen_salt('bf', 8));
        RETURN QUERY SELECT NULL::TEXT, NULL::TIMESTAMPTZ, 'invalid email or password'::TEXT;
        RETURN;
    END IF;

    IF v_locked_until > CURRENT_TIMESTAMP THEN
        RETURN QUERY SELECT NULL::TEXT, NULL::TIMESTAMPTZ,
            format('too many failed attempts; try again in %s seconds',
                   ceil(extract(epoch FROM v_locked_until - CURRENT_TIMESTAMP)));
        RETURN;
    END IF;

    IF extensions.crypt(COALESCE(p_password, ''), v_hash) <> v_hash THEN
        UPDATE ledger.user_credentials
        SET failed_attempts = CASE WHEN v_failed + 1 >= 5 THEN 0 ELSE v_failed + 1 END,
            locked_until = CASE WHEN v_failed + 1 >= 5
                                THEN CURRENT_TIMESTAMP + INTERVAL '5 minutes' END,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = v_user_id;
        RETURN QUERY SELECT NULL::TEXT, NULL::TIMESTAMPTZ, 'invalid email or password'::TEXT;
        RETURN;
    END IF;

    UPDATE ledger.user_credentials
    SET failed_attempts = 0, locked_until = NULL, updated_at = CURRENT_TIMESTAMP
    WHERE user_id = v_user_id;

    RETURN QUERY SELECT s.token, s.expires_at, NULL::TEXT FROM ledger.start_session(v_user_id) AS s;
END;
$$;

CREATE OR REPLACE FUNCTION ledger.log_out(p_token TEXT)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
    UPDATE ledger.sessions
    SET revoked_at = CURRENT_TIMESTAMP
    WHERE token_hash = ledger.hash_token(p_token)
      AND revoked_at IS NULL;
$$;

-- 4. The logged-in user's own wallet (granted to ledger_web) -------------------------

CREATE OR REPLACE FUNCTION ledger.my_wallet(p_token TEXT)
RETURNS TABLE (
    user_id BIGINT,
    account_id BIGINT,
    name TEXT,
    email TEXT,
    status ledger.account_status,
    balance BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_user_id BIGINT := ledger.authenticate(p_token);
BEGIN
    RETURN QUERY
    SELECT u.id, a.id, u.name::TEXT, u.email::TEXT, a.status, a.cached_balance
    FROM ledger.accounts AS a
    JOIN ledger.users AS u ON u.id = a.user_id
    WHERE u.id = v_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION ledger.my_history(
    p_token TEXT,
    p_cursor_created_at TIMESTAMPTZ DEFAULT NULL,
    p_cursor_id BIGINT DEFAULT NULL,
    p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
    entry_id BIGINT,
    transaction_id BIGINT,
    created_at TIMESTAMPTZ,
    type ledger.transaction_type,
    direction ledger.ledger_direction,
    amount BIGINT,
    signed_change BIGINT,
    other_party_account_id BIGINT,
    other_party TEXT,
    metadata JSONB,
    has_more BOOLEAN
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
    SELECT * FROM ledger.get_history(ledger.my_wallet_id(p_token), p_cursor_created_at, p_cursor_id, p_limit);
$$;

-- People you can pay: name and a masked email, never a balance. Excludes yourself.
CREATE OR REPLACE FUNCTION ledger.find_recipients(
    p_token TEXT,
    p_search TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (account_id BIGINT, name TEXT, masked_email TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_me BIGINT := ledger.authenticate(p_token);
BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 20 THEN
        RAISE EXCEPTION 'recipient limit must be between 1 and 20'
            USING ERRCODE = 'P1001';
    END IF;

    RETURN QUERY
    SELECT
        a.id,
        u.name::TEXT,
        (left(u.email, 1) || '***@' || split_part(u.email, '@', 2))::TEXT
    FROM ledger.accounts AS a
    JOIN ledger.users AS u ON u.id = a.user_id
    WHERE u.id <> v_me
      AND a.status = 'active'
      AND (
          p_search IS NULL
          OR btrim(p_search) = ''
          OR position(lower(btrim(p_search)) IN lower(u.name)) > 0
          OR lower(u.email) = lower(btrim(p_search))
      )
    ORDER BY a.id DESC
    LIMIT p_limit;
END;
$$;

-- Money movement: the source wallet always comes from the token, never from the request.
CREATE OR REPLACE FUNCTION ledger.my_top_up(p_token TEXT, p_amount BIGINT, p_idempotency_key TEXT)
RETURNS BIGINT
LANGUAGE sql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
    SELECT ledger.top_up(ledger.my_wallet_id(p_token), p_amount, p_idempotency_key);
$$;

CREATE OR REPLACE FUNCTION ledger.my_withdraw(p_token TEXT, p_amount BIGINT, p_idempotency_key TEXT)
RETURNS BIGINT
LANGUAGE sql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
    SELECT ledger.withdraw(ledger.my_wallet_id(p_token), p_amount, p_idempotency_key);
$$;

CREATE OR REPLACE FUNCTION ledger.my_transfer(
    p_token TEXT,
    p_recipient_account_id BIGINT,
    p_amount BIGINT,
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE sql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
    SELECT ledger.transfer(ledger.my_wallet_id(p_token), p_recipient_account_id, p_amount, p_idempotency_key);
$$;

-- Only the person who RECEIVED a transfer can refund it (like a shop refunding a buyer).
CREATE OR REPLACE FUNCTION ledger.my_refund(
    p_token TEXT,
    p_original_transaction_id BIGINT,
    p_amount BIGINT,
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_wallet_id BIGINT := ledger.my_wallet_id(p_token);
BEGIN
    PERFORM 1
    FROM ledger.transactions AS t
    JOIN ledger.ledger_entries AS e ON e.transaction_id = t.id
    WHERE t.id = p_original_transaction_id
      AND t.type = 'transfer'
      AND e.account_id = v_wallet_id
      AND e.direction = 'credit';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you can refund only a transfer you received'
            USING ERRCODE = 'P1001';
    END IF;

    RETURN ledger.refund(p_original_transaction_id, p_amount, p_idempotency_key);
END;
$$;

-- 5. Privileges ---------------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION
    ledger.hash_token(TEXT),
    ledger.set_password(BIGINT, TEXT),
    ledger.start_session(BIGINT),
    ledger.authenticate(TEXT),
    ledger.my_wallet_id(TEXT),
    ledger.sign_up(TEXT, TEXT, TEXT),
    ledger.log_in(TEXT, TEXT),
    ledger.log_out(TEXT),
    ledger.my_wallet(TEXT),
    ledger.my_history(TEXT, TIMESTAMPTZ, BIGINT, INTEGER),
    ledger.find_recipients(TEXT, TEXT, INTEGER),
    ledger.my_top_up(TEXT, BIGINT, TEXT),
    ledger.my_withdraw(TEXT, BIGINT, TEXT),
    ledger.my_transfer(TEXT, BIGINT, BIGINT, TEXT),
    ledger.my_refund(TEXT, BIGINT, BIGINT, TEXT)
FROM PUBLIC;

GRANT USAGE ON SCHEMA ledger TO ledger_web;
GRANT USAGE ON TYPE ledger.transaction_type, ledger.ledger_direction, ledger.account_status TO ledger_web;
GRANT EXECUTE ON FUNCTION
    ledger.sign_up(TEXT, TEXT, TEXT),
    ledger.log_in(TEXT, TEXT),
    ledger.log_out(TEXT),
    ledger.my_wallet(TEXT),
    ledger.my_history(TEXT, TIMESTAMPTZ, BIGINT, INTEGER),
    ledger.find_recipients(TEXT, TEXT, INTEGER),
    ledger.my_top_up(TEXT, BIGINT, TEXT),
    ledger.my_withdraw(TEXT, BIGINT, TEXT),
    ledger.my_transfer(TEXT, BIGINT, BIGINT, TEXT),
    ledger.my_refund(TEXT, BIGINT, BIGINT, TEXT),
    ledger.calculate_fee(BIGINT)
TO ledger_web;

RESET ROLE;
