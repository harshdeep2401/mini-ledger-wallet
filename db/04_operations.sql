-- Operation functions are the user-facing database API. They validate the
-- business request, build its ledger legs, and delegate all posting work to
-- post_transaction().

-- Required system accounts. They have no user_id; accounts.code identifies them.
INSERT INTO ledger.accounts (code, type)
VALUES ('BANK', 'asset')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ledger.accounts (code, type)
VALUES ('FEE_INCOME', 'income')
ON CONFLICT (code) DO NOTHING;

-- A successful idempotent retry normally returns its saved transaction. This
-- project also chose to reject that retry if any account in the saved posting
-- has since been frozen or closed, so check those accounts before returning it.
CREATE OR REPLACE FUNCTION ledger.assert_transaction_accounts_active(
    p_transaction_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_account RECORD;
    v_found_account BOOLEAN := FALSE;
BEGIN
    FOR v_account IN
        SELECT a.id, a.status
        FROM ledger.accounts AS a
        WHERE a.id IN (
            SELECT e.account_id
            FROM ledger.ledger_entries AS e
            WHERE e.transaction_id = p_transaction_id
        )
        ORDER BY a.id
        FOR UPDATE OF a
    LOOP
        v_found_account := TRUE;
        IF v_account.status <> 'active' THEN
            RAISE EXCEPTION 'account % is %; retry cannot be completed',
                v_account.id, v_account.status
                USING ERRCODE = 'P1001';
        END IF;
    END LOOP;

    IF NOT v_found_account THEN
        RAISE EXCEPTION 'saved transaction % has no accounts', p_transaction_id
            USING ERRCODE = 'P1001';
    END IF;
END;
$$;

-- INVARIANT: a user and their liability wallet are created together, so a
-- successful call cannot leave one without the other.
CREATE OR REPLACE FUNCTION ledger.create_user_with_wallet(
    p_name TEXT,
    p_email TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id BIGINT;
BEGIN
    IF p_name IS NULL OR length(btrim(p_name)) = 0 OR length(btrim(p_name)) > 100 THEN
        RAISE EXCEPTION 'name must contain between 1 and 100 characters'
            USING ERRCODE = 'P1001';
    END IF;

    IF p_email IS NULL
       OR length(btrim(p_email)) > 150
       OR btrim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
        RAISE EXCEPTION 'email address is missing or invalid'
            USING ERRCODE = 'P1001';
    END IF;

    -- This nested block makes both inserts atomic and translates duplicate
    -- email errors into the project's rule-violation code.
    BEGIN
        INSERT INTO ledger.users (name, email)
        VALUES (btrim(p_name), lower(btrim(p_email)))
        RETURNING id INTO v_user_id;

        INSERT INTO ledger.accounts (user_id, type)
        VALUES (v_user_id, 'liability');
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION 'email address is already registered'
                USING ERRCODE = 'P1001';
    END;

    -- Return the new user ID; its wallet is linked through accounts.user_id.
    RETURN v_user_id;
END;
$$;


-- INVARIANT: only an active user wallet can be frozen. The row lock makes a
-- concurrent posting or status change wait until this status transition ends.
CREATE OR REPLACE FUNCTION ledger.freeze_account(
    p_account_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_status ledger.account_status;
    v_user_id BIGINT;
BEGIN
    SELECT status, user_id
    INTO v_status, v_user_id
    FROM ledger.accounts
    WHERE id = p_account_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'account % does not exist', p_account_id
            USING ERRCODE = 'P1001';
    END IF;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'system accounts cannot be frozen'
            USING ERRCODE = 'P1001';
    END IF;

    IF v_status <> 'active' THEN
        RAISE EXCEPTION 'only an active account can be frozen; account % is %',
            p_account_id, v_status
            USING ERRCODE = 'P1001';
    END IF;

    UPDATE ledger.accounts
    SET status = 'frozen'
    WHERE id = p_account_id;

    RETURN p_account_id;
END;
$$;


-- INVARIANT: only a frozen user wallet can be unfrozen; closed and system
-- accounts remain unavailable through these operation functions.
CREATE OR REPLACE FUNCTION ledger.unfreeze_account(
    p_account_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_status ledger.account_status;
    v_user_id BIGINT;
BEGIN
    SELECT status, user_id
    INTO v_status, v_user_id
    FROM ledger.accounts
    WHERE id = p_account_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'account % does not exist', p_account_id
            USING ERRCODE = 'P1001';
    END IF;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'system accounts cannot be unfrozen'
            USING ERRCODE = 'P1001';
    END IF;

    IF v_status <> 'frozen' THEN
        RAISE EXCEPTION 'only a frozen account can be unfrozen; account % is %',
            p_account_id, v_status
            USING ERRCODE = 'P1001';
    END IF;

    UPDATE ledger.accounts
    SET status = 'active'
    WHERE id = p_account_id;

    RETURN p_account_id;
END;
$$;


-- INVARIANT: only an existing user wallet can be topped up, with a positive
-- amount in paise. post_transaction() checks account status and posts both legs.
CREATE OR REPLACE FUNCTION ledger.top_up(
    p_wallet_account_id BIGINT,
    p_amount BIGINT,
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_bank_account_id BIGINT;
    v_request_fingerprint BYTEA;
    v_saved_transaction_id BIGINT;
    v_transaction_id BIGINT;
BEGIN
    v_request_fingerprint := ledger.idempotency_fingerprint(
        'top_up',
        jsonb_build_object(
            'wallet_account_id', p_wallet_account_id,
            'amount', p_amount
        )
    );
    v_saved_transaction_id := ledger.check_idempotency(
        p_idempotency_key,
        v_request_fingerprint
    );

    IF v_saved_transaction_id IS NOT NULL THEN
        PERFORM ledger.assert_transaction_accounts_active(v_saved_transaction_id);
        RETURN v_saved_transaction_id;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'top-up amount must be a positive number of paise'
            USING ERRCODE = 'P1001';
    END IF;

    IF p_wallet_account_id IS NULL THEN
        RAISE EXCEPTION 'wallet account id is required'
            USING ERRCODE = 'P1001';
    END IF;

    PERFORM 1
    FROM ledger.accounts
    WHERE id = p_wallet_account_id
      AND user_id IS NOT NULL
      AND code IS NULL
      AND type = 'liability';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'account % is not an existing user wallet',
            p_wallet_account_id
            USING ERRCODE = 'P1001';
    END IF;

    SELECT id
    INTO v_bank_account_id
    FROM ledger.accounts
    WHERE code = 'BANK'
      AND user_id IS NULL
      AND type = 'asset';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'the BANK system account is missing or is not an asset'
            USING ERRCODE = 'P1001';
    END IF;

    -- Top-up legs: debit Bank, credit the wallet.
    v_transaction_id := ledger.post_transaction(
        p_type => 'topup'::ledger.transaction_type,
        p_legs => jsonb_build_array(
            jsonb_build_object(
                'account_id', v_bank_account_id,
                'direction', 'debit',
                'amount', p_amount
            ),
            jsonb_build_object(
                'account_id', p_wallet_account_id,
                'direction', 'credit',
                'amount', p_amount
            )
        ),
        p_idempotency_key => p_idempotency_key
    );

    PERFORM ledger.record_idempotency(
        p_idempotency_key,
        v_request_fingerprint,
        v_transaction_id
    );

    RETURN v_transaction_id;
END;
$$;


-- INVARIANT: only a user wallet can be withdrawn from. post_transaction()
-- checks the available balance after locking the wallet and Bank accounts.
CREATE OR REPLACE FUNCTION ledger.withdraw(
    p_wallet_account_id BIGINT,
    p_amount BIGINT,
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_bank_account_id BIGINT;
    v_request_fingerprint BYTEA;
    v_saved_transaction_id BIGINT;
    v_transaction_id BIGINT;
BEGIN
    v_request_fingerprint := ledger.idempotency_fingerprint(
        'withdraw',
        jsonb_build_object(
            'wallet_account_id', p_wallet_account_id,
            'amount', p_amount
        )
    );
    v_saved_transaction_id := ledger.check_idempotency(
        p_idempotency_key,
        v_request_fingerprint
    );

    IF v_saved_transaction_id IS NOT NULL THEN
        PERFORM ledger.assert_transaction_accounts_active(v_saved_transaction_id);
        RETURN v_saved_transaction_id;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'withdrawal amount must be a positive number of paise'
            USING ERRCODE = 'P1001';
    END IF;

    IF p_wallet_account_id IS NULL THEN
        RAISE EXCEPTION 'wallet account id is required'
            USING ERRCODE = 'P1001';
    END IF;

    PERFORM 1
    FROM ledger.accounts
    WHERE id = p_wallet_account_id
      AND user_id IS NOT NULL
      AND code IS NULL
      AND type = 'liability';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'account % is not an existing user wallet',
            p_wallet_account_id
            USING ERRCODE = 'P1001';
    END IF;

    SELECT id
    INTO v_bank_account_id
    FROM ledger.accounts
    WHERE code = 'BANK'
      AND user_id IS NULL
      AND type = 'asset';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'the BANK system account is missing or is not an asset'
            USING ERRCODE = 'P1001';
    END IF;

    -- Withdrawal legs: debit the wallet, credit Bank.
    v_transaction_id := ledger.post_transaction(
        p_type => 'withdrawal'::ledger.transaction_type,
        p_legs => jsonb_build_array(
            jsonb_build_object(
                'account_id', p_wallet_account_id,
                'direction', 'debit',
                'amount', p_amount
            ),
            jsonb_build_object(
                'account_id', v_bank_account_id,
                'direction', 'credit',
                'amount', p_amount
            )
        ),
        p_idempotency_key => p_idempotency_key
    );

    PERFORM ledger.record_idempotency(
        p_idempotency_key,
        v_request_fingerprint,
        v_transaction_id
    );

    RETURN v_transaction_id;
END;
$$;


-- INVARIANT: the fee is 0.5%, rounded half-up to a paisa, with a minimum of
-- 100 paise and a maximum of 1,000 paise. Constants are kept here by design.
CREATE OR REPLACE FUNCTION ledger.calculate_fee(
    p_amount BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_fee BIGINT;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'transfer amount must be a positive number of paise'
            USING ERRCODE = 'P1001';
    END IF;

    v_fee := round(p_amount::NUMERIC * 0.005)::BIGINT;
    RETURN LEAST(GREATEST(v_fee, 100), 1000);
END;
$$;


-- INVARIANT: transfers are between two different user wallets only. The sender
-- pays amount plus fee; the recipient receives amount; FEE_INCOME receives fee.
CREATE OR REPLACE FUNCTION ledger.transfer(
    p_sender_account_id BIGINT,
    p_recipient_account_id BIGINT,
    p_amount BIGINT,
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee BIGINT;
    v_sender_debit NUMERIC;
    v_wallet_count BIGINT;
    v_fee_account_id BIGINT;
    v_request_fingerprint BYTEA;
    v_saved_transaction_id BIGINT;
    v_transaction_id BIGINT;
BEGIN
    v_request_fingerprint := ledger.idempotency_fingerprint(
        'transfer',
        jsonb_build_object(
            'sender_account_id', p_sender_account_id,
            'recipient_account_id', p_recipient_account_id,
            'amount', p_amount
        )
    );
    v_saved_transaction_id := ledger.check_idempotency(
        p_idempotency_key,
        v_request_fingerprint
    );

    IF v_saved_transaction_id IS NOT NULL THEN
        PERFORM ledger.assert_transaction_accounts_active(v_saved_transaction_id);
        RETURN v_saved_transaction_id;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'transfer amount must be a positive number of paise'
            USING ERRCODE = 'P1001';
    END IF;

    IF p_sender_account_id IS NULL OR p_recipient_account_id IS NULL THEN
        RAISE EXCEPTION 'sender and recipient wallet IDs are required'
            USING ERRCODE = 'P1001';
    END IF;

    IF p_sender_account_id = p_recipient_account_id THEN
        RAISE EXCEPTION 'a wallet cannot transfer money to itself'
            USING ERRCODE = 'P1001';
    END IF;

    SELECT COUNT(*)
    INTO v_wallet_count
    FROM ledger.accounts
    WHERE id IN (p_sender_account_id, p_recipient_account_id)
      AND user_id IS NOT NULL
      AND code IS NULL
      AND type = 'liability';

    IF v_wallet_count <> 2 THEN
        RAISE EXCEPTION 'sender and recipient must both be existing user wallets'
            USING ERRCODE = 'P1001';
    END IF;

    SELECT id
    INTO v_fee_account_id
    FROM ledger.accounts
    WHERE code = 'FEE_INCOME'
      AND user_id IS NULL
      AND type = 'income';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'the FEE_INCOME system account is missing or is not income'
            USING ERRCODE = 'P1001';
    END IF;

    v_fee := ledger.calculate_fee(p_amount);
    v_sender_debit := p_amount::NUMERIC + v_fee;

    IF v_sender_debit > 9223372036854775807 THEN
        RAISE EXCEPTION 'transfer amount plus fee exceeds BIGINT capacity'
            USING ERRCODE = 'P1001';
    END IF;

    -- Transfer legs: debit amount+fee, credit amount, credit the fee.
    v_transaction_id := ledger.post_transaction(
        p_type => 'transfer'::ledger.transaction_type,
        p_legs => jsonb_build_array(
            jsonb_build_object(
                'account_id', p_sender_account_id,
                'direction', 'debit',
                'amount', v_sender_debit
            ),
            jsonb_build_object(
                'account_id', p_recipient_account_id,
                'direction', 'credit',
                'amount', p_amount
            ),
            jsonb_build_object(
                'account_id', v_fee_account_id,
                'direction', 'credit',
                'amount', v_fee
            )
        ),
        p_idempotency_key => p_idempotency_key
    );

    PERFORM ledger.record_idempotency(
        p_idempotency_key,
        v_request_fingerprint,
        v_transaction_id
    );

    RETURN v_transaction_id;
END;
$$;


-- INVARIANT: refunds are only for transfers and cannot exceed the original
-- recipient credit. Locking the original transaction serializes refund-cap
-- checks, so concurrent refunds cannot both spend the same remaining amount.
CREATE OR REPLACE FUNCTION ledger.refund(
    p_original_transaction_id BIGINT,
    p_amount BIGINT,
    p_idempotency_key TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_original_type ledger.transaction_type;
    v_sender_account_id BIGINT;
    v_recipient_account_id BIGINT;
    v_original_recipient_amount BIGINT;
    v_refunded_amount NUMERIC;
    v_matching_legs BIGINT;
    v_request_fingerprint BYTEA;
    v_saved_transaction_id BIGINT;
    v_transaction_id BIGINT;
BEGIN
    v_request_fingerprint := ledger.idempotency_fingerprint(
        'refund',
        jsonb_build_object(
            'original_transaction_id', p_original_transaction_id,
            'amount', p_amount
        )
    );
    v_saved_transaction_id := ledger.check_idempotency(
        p_idempotency_key,
        v_request_fingerprint
    );

    IF v_saved_transaction_id IS NOT NULL THEN
        PERFORM ledger.assert_transaction_accounts_active(v_saved_transaction_id);
        RETURN v_saved_transaction_id;
    END IF;

    IF p_original_transaction_id IS NULL THEN
        RAISE EXCEPTION 'original transaction ID is required'
            USING ERRCODE = 'P1001';
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'refund amount must be a positive number of paise'
            USING ERRCODE = 'P1001';
    END IF;

    -- All refund calls lock this immutable row before reading the refund total.
    SELECT type
    INTO v_original_type
    FROM ledger.transactions
    WHERE id = p_original_transaction_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'transaction % does not exist', p_original_transaction_id
            USING ERRCODE = 'P1001';
    END IF;

    IF v_original_type <> 'transfer' THEN
        RAISE EXCEPTION 'only a transfer can be refunded'
            USING ERRCODE = 'P1001';
    END IF;

    SELECT COUNT(*), MIN(e.account_id)
    INTO v_matching_legs, v_sender_account_id
    FROM ledger.ledger_entries AS e
    JOIN ledger.accounts AS a ON a.id = e.account_id
    WHERE e.transaction_id = p_original_transaction_id
      AND e.direction = 'debit'
      AND a.user_id IS NOT NULL
      AND a.type = 'liability';

    IF v_matching_legs <> 1 THEN
        RAISE EXCEPTION 'original transfer does not have exactly one sender wallet leg'
            USING ERRCODE = 'P1001';
    END IF;

    SELECT COUNT(*), MIN(e.account_id), MIN(e.amount)
    INTO v_matching_legs, v_recipient_account_id, v_original_recipient_amount
    FROM ledger.ledger_entries AS e
    JOIN ledger.accounts AS a ON a.id = e.account_id
    WHERE e.transaction_id = p_original_transaction_id
      AND e.direction = 'credit'
      AND a.user_id IS NOT NULL
      AND a.type = 'liability';

    IF v_matching_legs <> 1 THEN
        RAISE EXCEPTION 'original transfer does not have exactly one recipient wallet leg'
            USING ERRCODE = 'P1001';
    END IF;

    IF v_sender_account_id = v_recipient_account_id THEN
        RAISE EXCEPTION 'a self-transfer cannot be refunded'
            USING ERRCODE = 'P1001';
    END IF;

    SELECT COALESCE(SUM(e.amount), 0)
    INTO v_refunded_amount
    FROM ledger.transactions AS refund_transaction
    JOIN ledger.ledger_entries AS e
      ON e.transaction_id = refund_transaction.id
    WHERE refund_transaction.type = 'refund'
      AND refund_transaction.reverses_transaction_id = p_original_transaction_id
      AND e.account_id = v_recipient_account_id
      AND e.direction = 'debit';

    IF p_amount::NUMERIC + v_refunded_amount > v_original_recipient_amount THEN
        RAISE EXCEPTION 'refund exceeds the remaining refundable amount of % paise',
            v_original_recipient_amount - v_refunded_amount
            USING ERRCODE = 'P1001';
    END IF;

    -- Refund only the recipient's amount leg; the transfer fee is not returned.
    v_transaction_id := ledger.post_transaction(
        p_type => 'refund'::ledger.transaction_type,
        p_legs => jsonb_build_array(
            jsonb_build_object(
                'account_id', v_recipient_account_id,
                'direction', 'debit',
                'amount', p_amount
            ),
            jsonb_build_object(
                'account_id', v_sender_account_id,
                'direction', 'credit',
                'amount', p_amount
            )
        ),
        p_reverses_transaction_id => p_original_transaction_id,
        p_idempotency_key => p_idempotency_key
    );

    PERFORM ledger.record_idempotency(
        p_idempotency_key,
        v_request_fingerprint,
        v_transaction_id
    );

    RETURN v_transaction_id;
END;
$$;
