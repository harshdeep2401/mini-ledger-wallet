-- INVARIANTS (simulated admin login; no real money):
--   * Admins are separate from wallet users: their own table, sessions and log-in.
--     An admin has no wallet, and a user token is never accepted as an admin token.
--   * Admin sign-up needs a single-use invite code. Codes are stored only as SHA-256
--     hashes and are created by the owner (npm run db:seed:logins), never by the API.
--   * Every admin action available to the browser login (ledger_web) takes an admin
--     session token and checks it in the database before doing anything.
--   * Passwords are bcrypt hashes; tokens are SHA-256 hashes; 5 wrong passwords lock
--     the email for 5 minutes (failure returned as a value so the count commits).

SET ROLE ledger_owner;

-- 1. Tables -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ledger.admins (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(150) NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    failed_attempts INTEGER NOT NULL DEFAULT 0,
    locked_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT admins_email_lowercase_check CHECK (email = lower(email)),
    CONSTRAINT admins_failed_attempts_check CHECK (failed_attempts >= 0)
);

CREATE TABLE IF NOT EXISTS ledger.admin_sessions (
    token_hash BYTEA PRIMARY KEY,
    admin_id BIGINT NOT NULL REFERENCES ledger.admins(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    CONSTRAINT admin_sessions_expiry_check CHECK (expires_at > created_at)
);
CREATE INDEX IF NOT EXISTS admin_sessions_admin_id_idx ON ledger.admin_sessions (admin_id);

CREATE TABLE IF NOT EXISTS ledger.admin_invites (
    code_hash BYTEA PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    used_by BIGINT REFERENCES ledger.admins(id) ON DELETE RESTRICT,
    used_at TIMESTAMPTZ,
    CONSTRAINT admin_invites_used_check CHECK ((used_by IS NULL) = (used_at IS NULL))
);

REVOKE ALL ON ledger.admins, ledger.admin_sessions, ledger.admin_invites FROM PUBLIC;

-- 2. Internal helpers (never granted) ------------------------------------------------

CREATE OR REPLACE FUNCTION ledger.check_password_rules(p_password TEXT)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    IF p_password IS NULL OR length(p_password) < 8 OR octet_length(p_password) > 72 THEN
        RAISE EXCEPTION 'password must be 8 to 72 characters'
            USING ERRCODE = 'P1001';
    END IF;
END;
$$;

-- Creates an admin directly (used by the seed script) or by admin_sign_up().
CREATE OR REPLACE FUNCTION ledger.create_admin(p_name TEXT, p_email TEXT, p_password TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_admin_id BIGINT;
BEGIN
    IF p_name IS NULL OR length(btrim(p_name)) = 0 OR length(btrim(p_name)) > 100 THEN
        RAISE EXCEPTION 'name must be 1 to 100 characters'
            USING ERRCODE = 'P1001';
    END IF;
    IF p_email IS NULL OR length(btrim(p_email)) > 150
       OR btrim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
        RAISE EXCEPTION 'a valid email is required'
            USING ERRCODE = 'P1001';
    END IF;
    PERFORM ledger.check_password_rules(p_password);

    INSERT INTO ledger.admins (name, email, password_hash)
    VALUES (btrim(p_name), lower(btrim(p_email)),
            extensions.crypt(p_password, extensions.gen_salt('bf', 8)))
    ON CONFLICT (email) DO NOTHING
    RETURNING id INTO v_admin_id;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'admin email address is already registered'
            USING ERRCODE = 'P1001';
    END IF;
    RETURN v_admin_id;
END;
$$;

-- Adds a single-use invite code (stored hashed). Owner only.
CREATE OR REPLACE FUNCTION ledger.create_admin_invite(p_code TEXT)
RETURNS VOID
LANGUAGE plpgsql
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    IF p_code IS NULL OR length(p_code) < 8 THEN
        RAISE EXCEPTION 'invite code must be at least 8 characters'
            USING ERRCODE = 'P1001';
    END IF;
    INSERT INTO ledger.admin_invites (code_hash)
    VALUES (ledger.hash_token(p_code))
    ON CONFLICT (code_hash) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_start_session(p_admin_id BIGINT)
RETURNS TABLE (token TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_token TEXT := encode(extensions.gen_random_bytes(32), 'hex');
    v_expires TIMESTAMPTZ := CURRENT_TIMESTAMP + INTERVAL '8 hours';
BEGIN
    INSERT INTO ledger.admin_sessions (token_hash, admin_id, expires_at)
    VALUES (ledger.hash_token(v_token), p_admin_id, v_expires);
    RETURN QUERY SELECT v_token, v_expires;
END;
$$;

-- The admin behind a token, or SQLSTATE P1002 (the server answers 401).
CREATE OR REPLACE FUNCTION ledger.admin_authenticate(p_token TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_admin_id BIGINT;
BEGIN
    SELECT s.admin_id
    INTO v_admin_id
    FROM ledger.admin_sessions AS s
    WHERE s.token_hash = ledger.hash_token(p_token)
      AND s.revoked_at IS NULL
      AND s.expires_at > CURRENT_TIMESTAMP;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'admin log-in required, or the session has expired'
            USING ERRCODE = 'P1002';
    END IF;
    RETURN v_admin_id;
END;
$$;

-- 3. Admin sign up, log in, log out (granted to ledger_web) --------------------------

CREATE OR REPLACE FUNCTION ledger.admin_sign_up(
    p_name TEXT,
    p_email TEXT,
    p_password TEXT,
    p_invite_code TEXT
)
RETURNS TABLE (token TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_admin_id BIGINT;
BEGIN
    -- Lock the invite so two sign-ups cannot use the same code.
    PERFORM 1
    FROM ledger.admin_invites
    WHERE code_hash = ledger.hash_token(p_invite_code)
      AND used_by IS NULL
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'invalid or already used admin invite code'
            USING ERRCODE = 'P1001';
    END IF;

    v_admin_id := ledger.create_admin(p_name, p_email, p_password);

    UPDATE ledger.admin_invites
    SET used_by = v_admin_id, used_at = CURRENT_TIMESTAMP
    WHERE code_hash = ledger.hash_token(p_invite_code);

    RETURN QUERY SELECT * FROM ledger.admin_start_session(v_admin_id);
END;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_log_in(p_email TEXT, p_password TEXT)
RETURNS TABLE (token TEXT, expires_at TIMESTAMPTZ, error TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_admin ledger.admins%ROWTYPE;
BEGIN
    SELECT * INTO v_admin
    FROM ledger.admins
    WHERE email = lower(btrim(p_email))
    FOR UPDATE;

    IF NOT FOUND THEN
        PERFORM extensions.crypt(COALESCE(p_password, ''), extensions.gen_salt('bf', 8));
        RETURN QUERY SELECT NULL::TEXT, NULL::TIMESTAMPTZ, 'invalid email or password'::TEXT;
        RETURN;
    END IF;

    IF v_admin.locked_until > CURRENT_TIMESTAMP THEN
        RETURN QUERY SELECT NULL::TEXT, NULL::TIMESTAMPTZ,
            format('too many failed attempts; try again in %s seconds',
                   ceil(extract(epoch FROM v_admin.locked_until - CURRENT_TIMESTAMP)));
        RETURN;
    END IF;

    IF extensions.crypt(COALESCE(p_password, ''), v_admin.password_hash) <> v_admin.password_hash THEN
        UPDATE ledger.admins
        SET failed_attempts = CASE WHEN v_admin.failed_attempts + 1 >= 5 THEN 0 ELSE v_admin.failed_attempts + 1 END,
            locked_until = CASE WHEN v_admin.failed_attempts + 1 >= 5
                                THEN CURRENT_TIMESTAMP + INTERVAL '5 minutes' END
        WHERE id = v_admin.id;
        RETURN QUERY SELECT NULL::TEXT, NULL::TIMESTAMPTZ, 'invalid email or password'::TEXT;
        RETURN;
    END IF;

    UPDATE ledger.admins SET failed_attempts = 0, locked_until = NULL WHERE id = v_admin.id;
    RETURN QUERY SELECT s.token, s.expires_at, NULL::TEXT FROM ledger.admin_start_session(v_admin.id) AS s;
END;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_log_out(p_token TEXT)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
    UPDATE ledger.admin_sessions
    SET revoked_at = CURRENT_TIMESTAMP
    WHERE token_hash = ledger.hash_token(p_token)
      AND revoked_at IS NULL;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_me(p_token TEXT)
RETURNS TABLE (admin_id BIGINT, name TEXT, email TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_admin_id BIGINT := ledger.admin_authenticate(p_token);
BEGIN
    RETURN QUERY SELECT a.id, a.name::TEXT, a.email::TEXT FROM ledger.admins AS a WHERE a.id = v_admin_id;
END;
$$;

-- 4. Admin actions: check the token, then call the existing function ------------------

CREATE OR REPLACE FUNCTION ledger.admin_stats(p_token TEXT)
RETURNS TABLE (
    wallet_count BIGINT, wallet_total BIGINT, bank_balance BIGINT, fee_income BIGINT,
    books_difference BIGINT, transaction_count BIGINT, topups BIGINT, transfers BIGINT,
    withdrawals BIGINT, refunds BIGINT, last_minute BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    PERFORM ledger.admin_authenticate(p_token);
    RETURN QUERY SELECT * FROM ledger.ledger_stats();
END;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_feed(p_token TEXT, p_limit INTEGER DEFAULT 50, p_after_id BIGINT DEFAULT NULL)
RETURNS TABLE (
    transaction_id BIGINT, type ledger.transaction_type, reverses_transaction_id BIGINT,
    created_at TIMESTAMPTZ, from_label TEXT, to_label TEXT, amount BIGINT, fee BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    PERFORM ledger.admin_authenticate(p_token);
    RETURN QUERY SELECT * FROM ledger.recent_transactions(p_limit, p_after_id);
END;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_transaction(p_token TEXT, p_transaction_id BIGINT)
RETURNS TABLE (
    transaction_id BIGINT, type ledger.transaction_type, reverses_transaction_id BIGINT,
    created_at TIMESTAMPTZ, entry_id BIGINT, account_id BIGINT, account_label TEXT,
    direction ledger.ledger_direction, amount BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    PERFORM ledger.admin_authenticate(p_token);
    RETURN QUERY SELECT * FROM ledger.get_transaction(p_transaction_id);
END;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_transaction_refunds(p_token TEXT, p_transaction_id BIGINT)
RETURNS TABLE (refund_transaction_id BIGINT, created_at TIMESTAMPTZ, amount BIGINT, remaining_after BIGINT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    PERFORM ledger.admin_authenticate(p_token);
    RETURN QUERY SELECT * FROM ledger.transaction_refunds(p_transaction_id);
END;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_wallets(p_token TEXT, p_search TEXT DEFAULT NULL, p_limit INTEGER DEFAULT 50)
RETURNS TABLE (
    user_id BIGINT, account_id BIGINT, name TEXT, email TEXT,
    status ledger.account_status, balance BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    PERFORM ledger.admin_authenticate(p_token);
    RETURN QUERY SELECT * FROM ledger.list_wallets(p_search, p_limit);
END;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_freeze(p_token TEXT, p_account_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    PERFORM ledger.admin_authenticate(p_token);
    RETURN ledger.freeze_account(p_account_id);
END;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_unfreeze(p_token TEXT, p_account_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    PERFORM ledger.admin_authenticate(p_token);
    RETURN ledger.unfreeze_account(p_account_id);
END;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_reconciliation(p_token TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    PERFORM ledger.admin_authenticate(p_token);
    RETURN ledger.reconciliation_summary();
END;
$$;

CREATE OR REPLACE FUNCTION ledger.admin_reconciliation_issues(p_token TEXT)
RETURNS TABLE (
    check_name TEXT, account_id BIGINT, transaction_id BIGINT,
    expected TEXT, actual TEXT, difference NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    PERFORM ledger.admin_authenticate(p_token);
    RETURN QUERY SELECT * FROM ledger.reconciliation_issues();
END;
$$;

-- 5. Privileges ---------------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION
    ledger.check_password_rules(TEXT),
    ledger.create_admin(TEXT, TEXT, TEXT),
    ledger.create_admin_invite(TEXT),
    ledger.admin_start_session(BIGINT),
    ledger.admin_authenticate(TEXT),
    ledger.admin_sign_up(TEXT, TEXT, TEXT, TEXT),
    ledger.admin_log_in(TEXT, TEXT),
    ledger.admin_log_out(TEXT),
    ledger.admin_me(TEXT),
    ledger.admin_stats(TEXT),
    ledger.admin_feed(TEXT, INTEGER, BIGINT),
    ledger.admin_transaction(TEXT, BIGINT),
    ledger.admin_transaction_refunds(TEXT, BIGINT),
    ledger.admin_wallets(TEXT, TEXT, INTEGER),
    ledger.admin_freeze(TEXT, BIGINT),
    ledger.admin_unfreeze(TEXT, BIGINT),
    ledger.admin_reconciliation(TEXT),
    ledger.admin_reconciliation_issues(TEXT)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    ledger.admin_sign_up(TEXT, TEXT, TEXT, TEXT),
    ledger.admin_log_in(TEXT, TEXT),
    ledger.admin_log_out(TEXT),
    ledger.admin_me(TEXT),
    ledger.admin_stats(TEXT),
    ledger.admin_feed(TEXT, INTEGER, BIGINT),
    ledger.admin_transaction(TEXT, BIGINT),
    ledger.admin_transaction_refunds(TEXT, BIGINT),
    ledger.admin_wallets(TEXT, TEXT, INTEGER),
    ledger.admin_freeze(TEXT, BIGINT),
    ledger.admin_unfreeze(TEXT, BIGINT),
    ledger.admin_reconciliation(TEXT),
    ledger.admin_reconciliation_issues(TEXT)
TO ledger_web;

RESET ROLE;
