// One-off Phase 10 check: walk all entries for the hot FEE_INCOME account via
// get_history() and verify the (created_at, id) cursor returns each once.
import pg from 'pg';

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL is not set. Add it to the .env file in the project folder.');
  process.exit(1);
}

const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
client.on('notice', (notice) => console.log(notice.message));

const checkSql = `
BEGIN;
CREATE TEMP TABLE history_walk_seen (
    entry_id BIGINT PRIMARY KEY
) ON COMMIT DROP;

DO $$
DECLARE
    v_account_id BIGINT;
    v_expected_count BIGINT;
    v_seen_count BIGINT;
    v_timestamp_count BIGINT;
    v_cursor_created_at TIMESTAMPTZ := NULL;
    v_cursor_id BIGINT := NULL;
    v_last_created_at TIMESTAMPTZ;
    v_last_id BIGINT;
    v_page_count INTEGER;
    v_page_has_more BOOLEAN;
    v_entry RECORD;
BEGIN
    SELECT id INTO v_account_id
    FROM ledger.accounts
    WHERE code = 'FEE_INCOME';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FEE_INCOME system account is missing';
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT created_at)
    INTO v_expected_count, v_timestamp_count
    FROM ledger.ledger_entries
    WHERE account_id = v_account_id;
    IF v_expected_count < 100001 THEN
        RAISE EXCEPTION 'history walk needs at least 100,001 entries; found %', v_expected_count;
    END IF;
    IF v_timestamp_count < 2 THEN
        RAISE EXCEPTION 'history walk needs entries from multiple transaction timestamps';
    END IF;

    LOOP
        v_page_count := 0;
        v_page_has_more := FALSE;
        FOR v_entry IN
            SELECT *
            FROM ledger.get_history(
                v_account_id,
                v_cursor_created_at,
                v_cursor_id,
                100
            )
        LOOP
            INSERT INTO pg_temp.history_walk_seen (entry_id)
            VALUES (v_entry.entry_id);
            v_page_count := v_page_count + 1;
            v_last_created_at := v_entry.created_at;
            v_last_id := v_entry.entry_id;
            v_page_has_more := v_entry.has_more;
        END LOOP;

        EXIT WHEN v_page_count = 0 OR NOT v_page_has_more;
        v_cursor_created_at := v_last_created_at;
        v_cursor_id := v_last_id;
    END LOOP;

    SELECT COUNT(*) INTO v_seen_count FROM pg_temp.history_walk_seen;
    IF v_seen_count <> v_expected_count THEN
        RAISE EXCEPTION
            'history walk saw % entries, expected %', v_seen_count, v_expected_count;
    END IF;

    RAISE NOTICE
        'TEST PASSED: history walk returned % of % fee-account entries once across % timestamps',
        v_seen_count, v_expected_count, v_timestamp_count;
END;
$$;

ROLLBACK;
`;

try {
  await client.connect();
  await client.query(checkSql);
} catch (error) {
  console.error('History walk failed:', error.message);
  process.exitCode = 1;
  await client.query('ROLLBACK').catch(() => {});
} finally {
  await client.end();
}
