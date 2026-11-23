-- INVARIANT: the demo console can show a transaction's ledger legs and the balances of
-- chosen accounts (plus BANK and FEE_INCOME) without any table access. Both functions
-- are read-only. Added in Phase 12 for the live demo screens.

SET ROLE ledger_owner;

-- All legs of one transaction, in posting order. The caller can add up debits and credits.
CREATE OR REPLACE FUNCTION ledger.get_transaction(p_transaction_id BIGINT)
RETURNS TABLE (
    transaction_id BIGINT,
    type ledger.transaction_type,
    reverses_transaction_id BIGINT,
    created_at TIMESTAMPTZ,
    entry_id BIGINT,
    account_id BIGINT,
    account_label TEXT,
    direction ledger.ledger_direction,
    amount BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    IF p_transaction_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM ledger.transactions AS t WHERE t.id = p_transaction_id
    ) THEN
        RAISE EXCEPTION 'transaction % does not exist', p_transaction_id
            USING ERRCODE = 'P1001';
    END IF;

    RETURN QUERY
    SELECT
        t.id,
        t.type,
        t.reverses_transaction_id,
        t.created_at,
        e.id,
        a.id,
        COALESCE(a.code, u.name)::TEXT,
        e.direction,
        e.amount
    FROM ledger.transactions AS t
    JOIN ledger.ledger_entries AS e ON e.transaction_id = t.id
    JOIN ledger.accounts AS a ON a.id = e.account_id
    LEFT JOIN ledger.users AS u ON u.id = a.user_id
    WHERE t.id = p_transaction_id
    ORDER BY e.id;
END;
$$;

-- Cached balance and status for the given accounts, plus the system accounts
-- (BANK, FEE_INCOME) every time. At most 50 ids.
CREATE OR REPLACE FUNCTION ledger.account_overview(p_account_ids BIGINT[] DEFAULT NULL)
RETURNS TABLE (
    account_id BIGINT,
    label TEXT,
    code TEXT,
    status ledger.account_status,
    balance BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    IF COALESCE(cardinality(p_account_ids), 0) > 50 THEN
        RAISE EXCEPTION 'at most 50 accounts can be requested'
            USING ERRCODE = 'P1001';
    END IF;

    RETURN QUERY
    SELECT
        a.id,
        COALESCE(a.code, u.name)::TEXT,
        a.code,
        a.status,
        a.cached_balance
    FROM ledger.accounts AS a
    LEFT JOIN ledger.users AS u ON u.id = a.user_id
    WHERE a.code IS NOT NULL
       OR a.id = ANY (COALESCE(p_account_ids, ARRAY[]::BIGINT[]))
    ORDER BY (a.code IS NULL), a.id;
END;
$$;

REVOKE EXECUTE ON FUNCTION ledger.get_transaction(BIGINT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION ledger.account_overview(BIGINT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.get_transaction(BIGINT) TO ledger_app, ledger_reporting, ledger_admin;
GRANT EXECUTE ON FUNCTION ledger.account_overview(BIGINT[]) TO ledger_app, ledger_reporting, ledger_admin;

RESET ROLE;
