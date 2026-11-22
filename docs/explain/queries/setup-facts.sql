SELECT
    CURRENT_DATE AS captured_on,
    (SELECT COUNT(*) FROM ledger.transactions) AS transaction_count,
    (SELECT COUNT(*) FROM ledger.ledger_entries) AS entry_count,
    (SELECT COUNT(*) FROM ledger.accounts) AS account_count,
    (SELECT COUNT(*) FROM ledger.ledger_entries WHERE account_id = fee.id) AS fee_income_entry_count,
    pg_size_pretty(pg_total_relation_size('ledger.ledger_entries')) AS entries_total_size,
    pg_size_pretty(pg_indexes_size('ledger.ledger_entries')) AS entries_index_size
FROM ledger.accounts AS fee
WHERE fee.code = 'FEE_INCOME';
