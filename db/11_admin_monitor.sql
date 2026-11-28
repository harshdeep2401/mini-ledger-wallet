-- INVARIANT: the admin monitor can watch money move without any table access.
--   * A trigger announces every new transaction on channel 'ledger_events'.
--     PostgreSQL delivers NOTIFY only when the transaction COMMITS, so a
--     rolled-back (rejected) payment is never announced.
--   * recent_transactions, ledger_stats and transaction_refunds are read-only
--     and granted to ledger_admin and ledger_reporting only (not ledger_app).
-- Added for EXTENDED-FEATURES.md (live admin page).

SET ROLE ledger_owner;

-- 1. Live events -----------------------------------------------------------------

CREATE OR REPLACE FUNCTION ledger.notify_transaction_created()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    -- Small payload: listeners fetch details with recent_transactions().
    PERFORM pg_notify(
        'ledger_events',
        json_build_object('id', NEW.id, 'type', NEW.type)::TEXT
    );
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS notify_transaction_created ON ledger.transactions;
CREATE TRIGGER notify_transaction_created
AFTER INSERT ON ledger.transactions
FOR EACH ROW
EXECUTE FUNCTION ledger.notify_transaction_created();

-- 2. Feed: one summary row per transaction, newest first ---------------------------
-- from = accounts debited, to = accounts credited (except FEE_INCOME),
-- amount = what the receiving side got, fee = the FEE_INCOME credit.
-- p_after_id lets a listener fetch only transactions newer than the last one it saw.
CREATE OR REPLACE FUNCTION ledger.recent_transactions(
    p_limit INTEGER DEFAULT 50,
    p_after_id BIGINT DEFAULT NULL
)
RETURNS TABLE (
    transaction_id BIGINT,
    type ledger.transaction_type,
    reverses_transaction_id BIGINT,
    created_at TIMESTAMPTZ,
    from_label TEXT,
    to_label TEXT,
    amount BIGINT,
    fee BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 THEN
        RAISE EXCEPTION 'feed limit must be between 1 and 200'
            USING ERRCODE = 'P1001';
    END IF;

    RETURN QUERY
    SELECT
        t.id,
        t.type,
        t.reverses_transaction_id,
        t.created_at,
        string_agg(COALESCE(a.code, u.name), ', ' ORDER BY e.id)
            FILTER (WHERE e.direction = 'debit')::TEXT,
        string_agg(COALESCE(a.code, u.name), ', ' ORDER BY e.id)
            FILTER (WHERE e.direction = 'credit' AND a.code IS DISTINCT FROM 'FEE_INCOME')::TEXT,
        COALESCE(SUM(e.amount)
            FILTER (WHERE e.direction = 'credit' AND a.code IS DISTINCT FROM 'FEE_INCOME'), 0)::BIGINT,
        COALESCE(SUM(e.amount)
            FILTER (WHERE e.direction = 'credit' AND a.code = 'FEE_INCOME'), 0)::BIGINT
    FROM (
        -- Pick the transactions first so the primary key index does the work.
        SELECT tx.*
        FROM ledger.transactions AS tx
        WHERE p_after_id IS NULL OR tx.id > p_after_id
        ORDER BY tx.id DESC
        LIMIT p_limit
    ) AS t
    JOIN ledger.ledger_entries AS e ON e.transaction_id = t.id
    JOIN ledger.accounts AS a ON a.id = e.account_id
    LEFT JOIN ledger.users AS u ON u.id = a.user_id
    GROUP BY t.id, t.type, t.reverses_transaction_id, t.created_at
    ORDER BY t.id DESC;
END;
$$;

-- 3. Dashboard totals in one call --------------------------------------------------
-- Balances come from the cached balances; reconciliation is a separate check.
-- books_difference = BANK - (all wallets + FEE_INCOME). The accounting equation
-- (assets = liabilities + income) says it is always 0.
DROP FUNCTION IF EXISTS ledger.ledger_stats();
CREATE FUNCTION ledger.ledger_stats()
RETURNS TABLE (
    wallet_count BIGINT,
    wallet_total BIGINT,
    bank_balance BIGINT,
    fee_income BIGINT,
    books_difference BIGINT,
    transaction_count BIGINT,
    topups BIGINT,
    transfers BIGINT,
    withdrawals BIGINT,
    refunds BIGINT,
    last_minute BIGINT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
    WITH b AS (
        SELECT
            COUNT(*) FILTER (WHERE user_id IS NOT NULL) AS wallet_count,
            COALESCE(SUM(cached_balance) FILTER (WHERE user_id IS NOT NULL), 0)::BIGINT AS wallet_total,
            COALESCE(SUM(cached_balance) FILTER (WHERE code = 'BANK'), 0)::BIGINT AS bank_balance,
            COALESCE(SUM(cached_balance) FILTER (WHERE code = 'FEE_INCOME'), 0)::BIGINT AS fee_income
        FROM ledger.accounts
    )
    SELECT
        b.wallet_count,
        b.wallet_total,
        b.bank_balance,
        b.fee_income,
        b.bank_balance - b.wallet_total - b.fee_income,
        COUNT(t.id),
        COUNT(t.id) FILTER (WHERE t.type = 'topup'),
        COUNT(t.id) FILTER (WHERE t.type = 'transfer'),
        COUNT(t.id) FILTER (WHERE t.type = 'withdrawal'),
        COUNT(t.id) FILTER (WHERE t.type = 'refund'),
        COUNT(t.id) FILTER (WHERE t.created_at > CURRENT_TIMESTAMP - INTERVAL '1 minute')
    FROM b
    LEFT JOIN ledger.transactions AS t ON TRUE
    GROUP BY b.wallet_count, b.wallet_total, b.bank_balance, b.fee_income;
$$;

-- 4. Tracer: refunds made against one transfer, and what is left to refund --------
CREATE OR REPLACE FUNCTION ledger.transaction_refunds(p_transaction_id BIGINT)
RETURNS TABLE (
    refund_transaction_id BIGINT,
    created_at TIMESTAMPTZ,
    amount BIGINT,
    remaining_after BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_recipient_amount BIGINT;
BEGIN
    -- The refundable amount is the recipient wallet's credit on the transfer
    -- (the same rule refund() uses; the fee is never refunded).
    SELECT e.amount
    INTO v_recipient_amount
    FROM ledger.transactions AS t
    JOIN ledger.ledger_entries AS e ON e.transaction_id = t.id
    JOIN ledger.accounts AS a ON a.id = e.account_id
    WHERE t.id = p_transaction_id
      AND t.type = 'transfer'
      AND e.direction = 'credit'
      AND a.user_id IS NOT NULL;

    IF NOT FOUND THEN
        RETURN;  -- not a transfer: nothing can be refunded
    END IF;

    RETURN QUERY
    SELECT
        r.id,
        r.created_at,
        e.amount,
        (v_recipient_amount - SUM(e.amount) OVER (ORDER BY r.id))::BIGINT
    FROM ledger.transactions AS r
    JOIN ledger.ledger_entries AS e ON e.transaction_id = r.id AND e.direction = 'credit'
    WHERE r.type = 'refund'
      AND r.reverses_transaction_id = p_transaction_id
    ORDER BY r.id;
END;
$$;

REVOKE EXECUTE ON FUNCTION ledger.notify_transaction_created() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION ledger.recent_transactions(INTEGER, BIGINT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION ledger.ledger_stats() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION ledger.transaction_refunds(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.recent_transactions(INTEGER, BIGINT) TO ledger_admin, ledger_reporting;
GRANT EXECUTE ON FUNCTION ledger.ledger_stats() TO ledger_admin, ledger_reporting;
GRANT EXECUTE ON FUNCTION ledger.transaction_refunds(BIGINT) TO ledger_admin, ledger_reporting;

RESET ROLE;
