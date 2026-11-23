-- INVARIANT: the API can find wallets without reading any table. Returns user
-- wallets only (never BANK or FEE_INCOME), with the cached balance, and never
-- more than 200 rows, newest wallet first so a wallet just created is always on top.
-- Read-only; run as ledger_owner like the other functions.
-- Added in Phase 12 because the app role has no table access and create_user_with_wallet
-- returns only the user id.

SET ROLE ledger_owner;

CREATE OR REPLACE FUNCTION ledger.list_wallets(
    p_search TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 50
)
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
BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 THEN
        RAISE EXCEPTION 'wallet list limit must be between 1 and 200'
            USING ERRCODE = 'P1001';
    END IF;

    RETURN QUERY
    SELECT
        u.id,
        a.id,
        u.name::TEXT,
        u.email::TEXT,
        a.status,
        a.cached_balance
    FROM ledger.accounts AS a
    JOIN ledger.users AS u ON u.id = a.user_id
    WHERE a.user_id IS NOT NULL
      AND a.code IS NULL
      AND (
          p_search IS NULL
          OR btrim(p_search) = ''
          OR position(lower(btrim(p_search)) IN lower(u.name)) > 0
          OR position(lower(btrim(p_search)) IN lower(u.email)) > 0
      )
    ORDER BY a.id DESC
    LIMIT p_limit;
END;
$$;

REVOKE EXECUTE ON FUNCTION ledger.list_wallets(TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.list_wallets(TEXT, INTEGER)
    TO ledger_app, ledger_reporting, ledger_admin;

RESET ROLE;
