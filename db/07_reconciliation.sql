-- INVARIANT: this is one read-only statement, so all checks see one consistent
-- snapshot. The balance calculation intentionally repeats the normal-side
-- rule instead of calling posting code, keeping reconciliation independent.
CREATE OR REPLACE FUNCTION ledger.reconciliation_issues()
RETURNS TABLE (
    check_name TEXT,
    account_id BIGINT,
    transaction_id BIGINT,
    expected TEXT,
    actual TEXT,
    difference NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH global_totals AS (
        SELECT
            COALESCE(SUM(e.amount::NUMERIC) FILTER (WHERE e.direction = 'debit'), 0) AS debits,
            COALESCE(SUM(e.amount::NUMERIC) FILTER (WHERE e.direction = 'credit'), 0) AS credits
        FROM ledger.ledger_entries AS e
    ),
    transaction_totals AS (
        SELECT
            t.id AS transaction_id,
            COUNT(e.id) AS entry_count,
            COALESCE(SUM(e.amount::NUMERIC) FILTER (WHERE e.direction = 'debit'), 0) AS debits,
            COALESCE(SUM(e.amount::NUMERIC) FILTER (WHERE e.direction = 'credit'), 0) AS credits
        FROM ledger.transactions AS t
        LEFT JOIN ledger.ledger_entries AS e ON e.transaction_id = t.id
        GROUP BY t.id
    ),
    account_totals AS (
        SELECT
            a.id AS account_id,
            a.allow_negative,
            a.cached_balance::NUMERIC AS cached_balance,
            COALESCE(
                SUM(
                    CASE
                        WHEN (a.type IN ('asset', 'expense') AND e.direction = 'debit')
                          OR (a.type IN ('liability', 'income') AND e.direction = 'credit')
                        THEN e.amount::NUMERIC
                        ELSE -e.amount::NUMERIC
                    END
                ),
                0
            ) AS recomputed_balance
        FROM ledger.accounts AS a
        LEFT JOIN ledger.ledger_entries AS e ON e.account_id = a.id
        GROUP BY a.id, a.allow_negative, a.cached_balance, a.type
    ),
    transfer_limits AS (
        SELECT
            t.id AS transaction_id,
            COALESCE(
                SUM(e.amount::NUMERIC) FILTER (
                    WHERE e.direction = 'credit'
                      AND a.user_id IS NOT NULL
                      AND a.type = 'liability'
                ),
                0
            ) AS recipient_amount
        FROM ledger.transactions AS t
        LEFT JOIN ledger.ledger_entries AS e ON e.transaction_id = t.id
        LEFT JOIN ledger.accounts AS a ON a.id = e.account_id
        WHERE t.type = 'transfer'
        GROUP BY t.id
    ),
    refund_totals AS (
        SELECT
            original.id AS transaction_id,
            COALESCE(SUM(e.amount::NUMERIC) FILTER (WHERE e.direction = 'debit'), 0) AS refunded_amount
        FROM ledger.transactions AS original
        LEFT JOIN ledger.transactions AS refund
          ON refund.reverses_transaction_id = original.id
         AND refund.type = 'refund'
        LEFT JOIN ledger.ledger_entries AS e ON e.transaction_id = refund.id
        WHERE original.type = 'transfer'
        GROUP BY original.id
    )
    SELECT
        'global_debits_equal_credits'::TEXT,
        NULL::BIGINT,
        NULL::BIGINT,
        global_totals.debits::TEXT,
        global_totals.credits::TEXT,
        global_totals.credits - global_totals.debits
    FROM global_totals
    WHERE global_totals.debits <> global_totals.credits

    UNION ALL

    SELECT
        'transaction_debits_equal_credits'::TEXT,
        NULL::BIGINT,
        transaction_totals.transaction_id,
        CASE
            WHEN transaction_totals.entry_count = 0
            THEN 'at least 1 ledger entry'::TEXT
            ELSE transaction_totals.debits::TEXT
        END,
        CASE
            WHEN transaction_totals.entry_count = 0
            THEN '0 ledger entries'::TEXT
            ELSE transaction_totals.credits::TEXT
        END,
        CASE
            WHEN transaction_totals.entry_count = 0
            THEN NULL::NUMERIC
            ELSE transaction_totals.credits - transaction_totals.debits
        END
    FROM transaction_totals
    WHERE transaction_totals.entry_count = 0
       OR transaction_totals.debits <> transaction_totals.credits

    UNION ALL

    SELECT
        'account_cached_balance_matches_entries'::TEXT,
        account_totals.account_id,
        NULL::BIGINT,
        account_totals.recomputed_balance::TEXT,
        account_totals.cached_balance::TEXT,
        account_totals.cached_balance - account_totals.recomputed_balance
    FROM account_totals
    WHERE account_totals.cached_balance <> account_totals.recomputed_balance

    UNION ALL

    SELECT
        'account_balance_nonnegative'::TEXT,
        account_totals.account_id,
        NULL::BIGINT,
        '0'::TEXT,
        account_totals.recomputed_balance::TEXT,
        account_totals.recomputed_balance
    FROM account_totals
    WHERE NOT account_totals.allow_negative
      AND account_totals.recomputed_balance < 0

    UNION ALL

    SELECT
        'idempotency_key_matches_transaction'::TEXT,
        NULL::BIGINT,
        idempotency.transaction_id,
        idempotency.idempotency_key,
        transaction_row.idempotency_key,
        NULL::NUMERIC
    FROM ledger.idempotency_keys AS idempotency
    LEFT JOIN ledger.transactions AS transaction_row
      ON transaction_row.id = idempotency.transaction_id
    WHERE transaction_row.id IS NULL
       OR transaction_row.idempotency_key IS DISTINCT FROM idempotency.idempotency_key

    UNION ALL

    SELECT
        'refund_within_transfer_amount'::TEXT,
        NULL::BIGINT,
        transfer_limits.transaction_id,
        transfer_limits.recipient_amount::TEXT,
        refund_totals.refunded_amount::TEXT,
        refund_totals.refunded_amount - transfer_limits.recipient_amount
    FROM transfer_limits
    JOIN refund_totals USING (transaction_id)
    WHERE refund_totals.refunded_amount > transfer_limits.recipient_amount;
$$;


-- A scalar result distinguishes a successful healthy run (TRUE) from the
-- detail function's empty set, which could otherwise be mistaken for no run.
CREATE OR REPLACE FUNCTION ledger.reconciliation_summary()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT NOT EXISTS (
        SELECT 1
        FROM ledger.reconciliation_issues()
    );
$$;
