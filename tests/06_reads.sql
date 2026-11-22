-- Run after db/06_reads.sql. All fixtures and postings roll back at the end.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    bank_account_id BIGINT;
    sender_user_id BIGINT;
    recipient_user_id BIGINT;
    empty_user_id BIGINT;
    page_user_id BIGINT;
    sender_wallet_id BIGINT;
    recipient_wallet_id BIGINT;
    empty_wallet_id BIGINT;
    page_wallet_id BIGINT;
    transfer_id BIGINT;
    refund_id BIGINT;
    account_id_missing BIGINT;
    rejected BOOLEAN;
    email_suffix TEXT := md5(clock_timestamp()::TEXT || random()::TEXT);
    history_row RECORD;
    sender_transfer_row RECORD;
    recipient_transfer_row RECORD;
    sender_refund_row RECORD;
    recipient_refund_row RECORD;
    page_count INTEGER;
    page_number INTEGER;
    total_rows INTEGER;
    cursor_created_at TIMESTAMPTZ;
    cursor_id BIGINT;
    first_page_cursor_created_at TIMESTAMPTZ;
    first_page_cursor_id BIGINT;
    page_ids BIGINT[];
    page_legs JSONB;
    new_transaction_id BIGINT;
    first_page_newest_transaction_id BIGINT;
    balance_sum NUMERIC;
BEGIN
    SELECT id INTO bank_account_id FROM ledger.accounts WHERE code = 'BANK';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEST FAILED: BANK system account is missing';
    END IF;

    SELECT ledger.create_user_with_wallet('Read Test Sender', 'reads-sender-' || email_suffix || '@example.test')
    INTO sender_user_id;
    SELECT ledger.create_user_with_wallet('Read Test Recipient', 'reads-recipient-' || email_suffix || '@example.test')
    INTO recipient_user_id;
    SELECT ledger.create_user_with_wallet('Read Test Empty', 'reads-empty-' || email_suffix || '@example.test')
    INTO empty_user_id;
    SELECT ledger.create_user_with_wallet('Read Test Pages', 'reads-pages-' || email_suffix || '@example.test')
    INTO page_user_id;

    SELECT id INTO sender_wallet_id FROM ledger.accounts WHERE user_id = sender_user_id;
    SELECT id INTO recipient_wallet_id FROM ledger.accounts WHERE user_id = recipient_user_id;
    SELECT id INTO empty_wallet_id FROM ledger.accounts WHERE user_id = empty_user_id;
    SELECT id INTO page_wallet_id FROM ledger.accounts WHERE user_id = page_user_id;

    IF ledger.get_balance(sender_wallet_id) <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: a fresh wallet balance was not zero';
    END IF;
    RAISE NOTICE 'TEST PASSED: fresh wallet balance is zero';

    -- Top up 1,000 rupees, transfer 500 (fee 2.50), then withdraw 200.
    PERFORM ledger.top_up(sender_wallet_id, 100000, 'reads-main-topup');
    transfer_id := ledger.transfer(sender_wallet_id, recipient_wallet_id, 50000, 'reads-main-transfer');
    PERFORM ledger.withdraw(sender_wallet_id, 20000, 'reads-main-withdraw');

    IF ledger.get_balance(sender_wallet_id) <> 29750
       OR ledger.get_balance(recipient_wallet_id) <> 50000 THEN
        RAISE EXCEPTION 'TEST FAILED: balance after top-up, transfer and withdrawal is incorrect';
    END IF;
    RAISE NOTICE 'TEST PASSED: cached balances include transfer fee and withdrawal';

    SELECT COUNT(*) INTO total_rows
    FROM ledger.get_history(sender_wallet_id, NULL, NULL, 10);
    IF total_rows <> 3
       OR EXISTS (
           SELECT 1 FROM ledger.get_history(sender_wallet_id, NULL, NULL, 10)
           WHERE has_more
       ) THEN
        RAISE EXCEPTION 'TEST FAILED: short history page row count or has_more is incorrect';
    END IF;

    SELECT * INTO sender_transfer_row
    FROM ledger.get_history(sender_wallet_id, NULL, NULL, 10)
    WHERE transaction_id = transfer_id;
    SELECT * INTO recipient_transfer_row
    FROM ledger.get_history(recipient_wallet_id, NULL, NULL, 10)
    WHERE transaction_id = transfer_id;
    IF sender_transfer_row.entry_id IS NULL
       OR sender_transfer_row.type <> 'transfer'
       OR sender_transfer_row.direction <> 'debit'
       OR sender_transfer_row.amount <> 50250
       OR sender_transfer_row.signed_change <> -50250
       OR sender_transfer_row.other_party_account_id <> recipient_wallet_id
       OR sender_transfer_row.other_party <> 'Read Test Recipient'
       OR recipient_transfer_row.entry_id IS NULL
       OR recipient_transfer_row.direction <> 'credit'
       OR recipient_transfer_row.amount <> 50000
       OR recipient_transfer_row.signed_change <> 50000
       OR recipient_transfer_row.other_party_account_id <> sender_wallet_id
       OR recipient_transfer_row.other_party <> 'Read Test Sender' THEN
        RAISE EXCEPTION 'TEST FAILED: sender or recipient transfer history is incorrect';
    END IF;
    RAISE NOTICE 'TEST PASSED: transfer histories show signed amounts and the other wallet';

    -- One balanced posting creates 25 entries for this wallet in the same
    -- transaction. Thirteen credits and twelve debits leave its balance +1;
    -- the bank debit balances the remaining one-paisa difference.
    page_legs := jsonb_build_array(
        jsonb_build_object('account_id', bank_account_id, 'direction', 'debit', 'amount', 1)
    );
    FOR page_number IN 1..13 LOOP
        page_legs := page_legs || jsonb_build_array(
            jsonb_build_object('account_id', page_wallet_id, 'direction', 'credit', 'amount', 1)
        );
    END LOOP;
    FOR page_number IN 1..12 LOOP
        page_legs := page_legs || jsonb_build_array(
            jsonb_build_object('account_id', page_wallet_id, 'direction', 'debit', 'amount', 1)
        );
    END LOOP;
    PERFORM ledger.post_transaction('topup', page_legs);

    page_ids := ARRAY[]::BIGINT[];
    cursor_created_at := NULL;
    cursor_id := NULL;
    page_number := 0;
    LOOP
        page_count := 0;
        FOR history_row IN
            SELECT * FROM ledger.get_history(page_wallet_id, cursor_created_at, cursor_id, 10)
        LOOP
            page_count := page_count + 1;
            page_ids := array_append(page_ids, history_row.entry_id);
            cursor_created_at := history_row.created_at;
            cursor_id := history_row.entry_id;
            IF history_row.has_more <> (page_number < 2) THEN
                RAISE EXCEPTION 'TEST FAILED: has_more was wrong on page %', page_number + 1;
            END IF;
        END LOOP;
        IF page_count = 0 THEN
            EXIT;
        END IF;
        page_number := page_number + 1;
        IF page_count <> (CASE WHEN page_number < 3 THEN 10 ELSE 5 END) THEN
            RAISE EXCEPTION 'TEST FAILED: page % returned % rows', page_number, page_count;
        END IF;
        IF page_number > 3 THEN
            RAISE EXCEPTION 'TEST FAILED: pagination did not terminate within three pages';
        END IF;
    END LOOP;

    IF cardinality(page_ids) <> 25
       OR (SELECT COUNT(DISTINCT entry_id) FROM unnest(page_ids) AS ids(entry_id)) <> 25 THEN
        RAISE EXCEPTION 'TEST FAILED: walking pages repeated or missed history entries';
    END IF;
    IF (SELECT COUNT(DISTINCT transaction_id)
        FROM ledger.ledger_entries WHERE account_id = page_wallet_id) <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: same-timestamp page fixture is not one transaction';
    END IF;
    FOR page_number IN 2..cardinality(page_ids) LOOP
        IF page_ids[page_number] >= page_ids[page_number - 1] THEN
            RAISE EXCEPTION 'TEST FAILED: same-timestamp history entries are not newest first';
        END IF;
    END LOOP;
    RAISE NOTICE 'TEST PASSED: all 25 history rows appear once in order across pages';

    -- Capture page 1's cursor, post another entry, and continue from the old
    -- cursor. The new row belongs at the top of a fresh walk, not page 2.
    SELECT created_at, entry_id
    INTO first_page_cursor_created_at, first_page_cursor_id
    FROM ledger.get_history(page_wallet_id, NULL, NULL, 10)
    ORDER BY created_at ASC, entry_id ASC
    LIMIT 1;
    new_transaction_id := ledger.top_up(page_wallet_id, 1, 'reads-page-arrival');

    IF EXISTS (
        SELECT 1
        FROM ledger.get_history(page_wallet_id, first_page_cursor_created_at, first_page_cursor_id, 10)
        WHERE transaction_id = new_transaction_id
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: a new posting appeared behind an already-fetched cursor';
    END IF;
    SELECT transaction_id INTO first_page_newest_transaction_id
    FROM ledger.get_history(page_wallet_id, NULL, NULL, 10)
    ORDER BY created_at DESC, entry_id DESC
    LIMIT 1;
    IF first_page_newest_transaction_id <> new_transaction_id THEN
        RAISE EXCEPTION 'TEST FAILED: new posting was not visible at the top of a fresh history page';
    END IF;
    RAISE NOTICE 'TEST PASSED: a posting between pages appears only on a fresh first page';

    -- Refund the transfer. The refund reverses the recipient amount only;
    -- sender and recipient histories must show opposite signed changes.
    refund_id := ledger.refund(transfer_id, 50000, 'reads-main-refund');
    SELECT * INTO sender_refund_row
    FROM ledger.get_history(sender_wallet_id, NULL, NULL, 10)
    WHERE transaction_id = refund_id;
    SELECT * INTO recipient_refund_row
    FROM ledger.get_history(recipient_wallet_id, NULL, NULL, 10)
    WHERE transaction_id = refund_id;
    IF sender_refund_row.entry_id IS NULL
       OR sender_refund_row.type <> 'refund'
       OR sender_refund_row.signed_change <> 50000
       OR sender_refund_row.other_party_account_id <> recipient_wallet_id
       OR recipient_refund_row.entry_id IS NULL
       OR recipient_refund_row.type <> 'refund'
       OR recipient_refund_row.signed_change <> -50000
       OR recipient_refund_row.other_party_account_id <> sender_wallet_id THEN
        RAISE EXCEPTION 'TEST FAILED: refund histories have incorrect signs or other parties';
    END IF;
    RAISE NOTICE 'TEST PASSED: refund appears with opposite signed changes in both histories';

    IF ledger.get_balance(empty_wallet_id) <> 0
       OR EXISTS (SELECT 1 FROM ledger.get_history(empty_wallet_id, NULL, NULL, 20)) THEN
        RAISE EXCEPTION 'TEST FAILED: empty account balance or history is incorrect';
    END IF;
    RAISE NOTICE 'TEST PASSED: an account with no entries returns an empty history';

    SELECT COALESCE(MAX(id), 0) + 1 INTO account_id_missing FROM ledger.accounts;
    rejected := FALSE;
    BEGIN
        PERFORM ledger.get_balance(account_id_missing);
    EXCEPTION WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: get_balance accepted a nonexistent account';
    END IF;
    RAISE NOTICE 'TEST PASSED: nonexistent account balance raises P1001';

    FOR total_rows IN SELECT unnest(ARRAY[0, -1, 101]) LOOP
        rejected := FALSE;
        BEGIN
            PERFORM * FROM ledger.get_history(sender_wallet_id, NULL, NULL, total_rows);
        EXCEPTION WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
        END;
        IF NOT rejected THEN
            RAISE EXCEPTION 'TEST FAILED: get_history accepted invalid limit %', total_rows;
        END IF;
    END LOOP;
    RAISE NOTICE 'TEST PASSED: zero, negative and over-maximum limits raise P1001';

    rejected := FALSE;
    BEGIN
        PERFORM * FROM ledger.get_history(sender_wallet_id, NULL, 1, 10);
    EXCEPTION WHEN SQLSTATE 'P1001' THEN rejected := TRUE;
    END;
    IF NOT rejected THEN
        RAISE EXCEPTION 'TEST FAILED: get_history accepted an incomplete cursor';
    END IF;
    RAISE NOTICE 'TEST PASSED: incomplete cursor pair raises P1001';

    -- Reconcile the cached balances against all signed history for each wallet
    -- created in this test, using the maximum allowed page size.
    FOR history_row IN
        SELECT id, cached_balance
        FROM ledger.accounts
        WHERE id IN (sender_wallet_id, recipient_wallet_id, empty_wallet_id, page_wallet_id)
    LOOP
        SELECT COALESCE(SUM(signed_change), 0)
        INTO balance_sum
        FROM ledger.get_history(history_row.id, NULL, NULL, 100);
        IF balance_sum <> history_row.cached_balance THEN
            RAISE EXCEPTION 'TEST FAILED: wallet % cached balance % differs from history sum %',
                history_row.id, history_row.cached_balance, balance_sum;
        END IF;
    END LOOP;
    RAISE NOTICE 'TEST PASSED: cached balances equal the signed history sum';

    SET CONSTRAINTS ALL IMMEDIATE;
END;
$$;

ROLLBACK;
