EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT
    e.id AS entry_id,
    e.transaction_id,
    e.created_at,
    t.type,
    e.direction,
    e.amount,
    t.metadata
FROM ledger.ledger_entries AS e
JOIN ledger.transactions AS t ON t.id = e.transaction_id
WHERE e.account_id = $1::BIGINT
  AND (e.created_at, e.id) < ($2::TIMESTAMPTZ, $3::BIGINT)
ORDER BY e.created_at DESC, e.id DESC
LIMIT 20;
