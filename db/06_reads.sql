-- History index: equality filter on account_id, followed by the descending
-- (created_at, id) keyset order used by get_history().
CREATE INDEX idx_ledger_entries_account_history
ON ledger.ledger_entries (account_id, created_at DESC, id DESC);


-- INVARIANT: the normal read path returns the cached balance. Phase 8
-- reconciliation checks that it agrees with the signed ledger entries.
CREATE OR REPLACE FUNCTION ledger.get_balance(
    p_account_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_balance BIGINT;
BEGIN
    SELECT cached_balance
    INTO v_balance
    FROM ledger.accounts
    WHERE id = p_account_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'account % does not exist', p_account_id
            USING ERRCODE = 'P1001';
    END IF;

    RETURN v_balance;
END;
$$;


-- INVARIANTS: one result row per ledger entry; pages are newest first and
-- continue strictly after the (created_at, id) cursor. The extra candidate row
-- is used only to set has_more; it is never returned as a history row.
CREATE OR REPLACE FUNCTION ledger.get_history(
    p_account_id BIGINT,
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
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
        RAISE EXCEPTION 'history limit must be between 1 and 100'
            USING ERRCODE = 'P1001';
    END IF;

    IF (p_cursor_created_at IS NULL) <> (p_cursor_id IS NULL) THEN
        RAISE EXCEPTION 'both history cursor values must be supplied together'
            USING ERRCODE = 'P1001';
    END IF;

    PERFORM 1
    FROM ledger.accounts
    WHERE id = p_account_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'account % does not exist', p_account_id
            USING ERRCODE = 'P1001';
    END IF;

    RETURN QUERY
    WITH candidates AS MATERIALIZED (
        SELECT
            e.id AS entry_id,
            e.transaction_id,
            e.created_at,
            t.type AS transaction_type,
            e.direction,
            e.amount,
            CASE
                WHEN (a.type IN ('asset', 'expense') AND e.direction = 'debit')
                  OR (a.type IN ('liability', 'income') AND e.direction = 'credit')
                THEN e.amount
                ELSE -e.amount
            END AS signed_change,
            other_party.account_id AS other_party_account_id,
            other_party.display_name AS other_party,
            t.metadata
        FROM ledger.ledger_entries AS e
        JOIN ledger.transactions AS t ON t.id = e.transaction_id
        JOIN ledger.accounts AS a ON a.id = e.account_id
        LEFT JOIN LATERAL (
            SELECT
                other_entry.account_id,
                COALESCE(other_user.name::TEXT, other_account.code, 'Unknown') AS display_name
            FROM ledger.ledger_entries AS other_entry
            JOIN ledger.accounts AS other_account
              ON other_account.id = other_entry.account_id
            LEFT JOIN ledger.users AS other_user
              ON other_user.id = other_account.user_id
            WHERE other_entry.transaction_id = e.transaction_id
              AND other_entry.account_id <> e.account_id
            ORDER BY
                CASE WHEN other_account.user_id IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN other_entry.direction = 'debit' THEN 0 ELSE 1 END,
                other_entry.id
            LIMIT 1
        ) AS other_party ON TRUE
        WHERE e.account_id = p_account_id
          AND (
              p_cursor_created_at IS NULL
              OR (e.created_at, e.id) < (p_cursor_created_at, p_cursor_id)
          )
        ORDER BY e.created_at DESC, e.id DESC
        LIMIT (p_limit + 1)
    ),
    page AS (
        SELECT
            candidate.*,
            (SELECT COUNT(*) > p_limit FROM candidates) AS has_more
        FROM candidates AS candidate
        ORDER BY candidate.created_at DESC, candidate.entry_id DESC
        LIMIT p_limit
    )
    SELECT
        page.entry_id,
        page.transaction_id,
        page.created_at,
        page.transaction_type,
        page.direction,
        page.amount,
        page.signed_change,
        page.other_party_account_id,
        page.other_party,
        page.metadata,
        page.has_more
    FROM page
    ORDER BY page.created_at DESC, page.entry_id DESC;
END;
$$;
