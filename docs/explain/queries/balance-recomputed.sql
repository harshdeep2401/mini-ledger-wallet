EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT COALESCE(
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
WHERE a.id = $1::BIGINT
GROUP BY a.id, a.type;
