-- INVARIANTS: locks every affected account in ascending ID order, rejects
-- invalid or unbalanced postings and overdrafts, writes the transaction and
-- all entries together, and keeps cached balances consistent with the ledger.
-- Callers pass legs as a JSONB array, for example:
-- [{"account_id": 12, "direction": "debit", "amount": 505}, ...]

CREATE OR REPLACE FUNCTION ledger.post_transaction(
    p_type ledger.transaction_type,
    p_legs JSONB,
    p_reverses_transaction_id BIGINT DEFAULT NULL,
    p_metadata JSONB DEFAULT NULL,
    p_idempotency_key TEXT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_leg JSONB;
    v_account_id_numeric NUMERIC;
    v_amount_numeric NUMERIC;
    v_requested_account_count BIGINT;
    v_locked_account_count BIGINT := 0;
    v_account RECORD;
    v_change RECORD;
    v_transaction_id BIGINT;
    v_created_at TIMESTAMPTZ;
BEGIN
    -- Validate transaction-level fields and the shape of the legs array.
    IF p_type IS NULL THEN
        RAISE EXCEPTION 'transaction type is required'
            USING ERRCODE = 'P1001';
    END IF;

    IF (p_type = 'refund' AND p_reverses_transaction_id IS NULL)
       OR (p_type <> 'refund' AND p_reverses_transaction_id IS NOT NULL) THEN
        RAISE EXCEPTION 'only refunds must reference the transaction they reverse'
            USING ERRCODE = 'P1001';
    END IF;

    IF p_legs IS NULL OR jsonb_typeof(p_legs) <> 'array' THEN
        RAISE EXCEPTION 'legs must be a JSON array'
            USING ERRCODE = 'P1001';
    END IF;

    IF jsonb_array_length(p_legs) < 2 THEN
        RAISE EXCEPTION 'a posting must contain at least two legs'
            USING ERRCODE = 'P1001';
    END IF;

    -- Validate each leg before casting its values to BIGINT or an enum.
    FOR v_leg IN
        SELECT element
        FROM jsonb_array_elements(p_legs) AS legs(element)
    LOOP
        IF jsonb_typeof(v_leg) <> 'object'
           OR NOT (v_leg ? 'account_id')
           OR NOT (v_leg ? 'direction')
           OR NOT (v_leg ? 'amount') THEN
            RAISE EXCEPTION 'each leg must be an object with account_id, direction, and amount'
                USING ERRCODE = 'P1001';
        END IF;

        IF jsonb_typeof(v_leg->'account_id') <> 'number'
           OR jsonb_typeof(v_leg->'amount') <> 'number'
           OR jsonb_typeof(v_leg->'direction') <> 'string' THEN
            RAISE EXCEPTION 'leg account_id and amount must be numbers, and direction must be text'
                USING ERRCODE = 'P1001';
        END IF;

        v_account_id_numeric := (v_leg->>'account_id')::NUMERIC;
        v_amount_numeric := (v_leg->>'amount')::NUMERIC;

        IF v_account_id_numeric <> trunc(v_account_id_numeric)
           OR v_account_id_numeric < 1
           OR v_account_id_numeric > 9223372036854775807 THEN
            RAISE EXCEPTION 'leg account_id must be a positive BIGINT'
                USING ERRCODE = 'P1001';
        END IF;

        IF v_amount_numeric <> trunc(v_amount_numeric)
           OR v_amount_numeric < 1
           OR v_amount_numeric > 9223372036854775807 THEN
            RAISE EXCEPTION 'leg amount must be a positive whole number of paise'
                USING ERRCODE = 'P1001';
        END IF;

        IF v_leg->>'direction' NOT IN ('debit', 'credit') THEN
            RAISE EXCEPTION 'leg direction must be debit or credit'
                USING ERRCODE = 'P1001';
        END IF;
    END LOOP;

    -- Reject unbalanced legs here for a clear, immediate error. The deferred
    -- trigger remains as protection against inserts made outside this function.
    IF (
        SELECT COALESCE(SUM((element->>'amount')::NUMERIC)
                        FILTER (WHERE element->>'direction' = 'debit'), 0)
             <> COALESCE(SUM((element->>'amount')::NUMERIC)
                        FILTER (WHERE element->>'direction' = 'credit'), 0)
        FROM jsonb_array_elements(p_legs) AS legs(element)
    ) THEN
        RAISE EXCEPTION 'posting legs are not balanced: debit and credit totals differ'
            USING ERRCODE = 'P1001';
    END IF;

    SELECT COUNT(DISTINCT (element->>'account_id')::NUMERIC::BIGINT)
    INTO v_requested_account_count
    FROM jsonb_array_elements(p_legs) AS legs(element);

    -- Lock each distinct account in a stable order before reading its balance.
    FOR v_account IN
        SELECT a.id, a.status
        FROM ledger.accounts AS a
        JOIN (
            SELECT DISTINCT (element->>'account_id')::NUMERIC::BIGINT AS account_id
            FROM jsonb_array_elements(p_legs) AS legs(element)
        ) AS requested ON requested.account_id = a.id
        ORDER BY a.id
        FOR UPDATE OF a
    LOOP
        v_locked_account_count := v_locked_account_count + 1;

        IF v_account.status <> 'active' THEN
            RAISE EXCEPTION 'account % cannot be posted to because its status is %',
                v_account.id, v_account.status
                USING ERRCODE = 'P1001';
        END IF;
    END LOOP;

    IF v_locked_account_count <> v_requested_account_count THEN
        RAISE EXCEPTION 'one or more posting accounts do not exist'
            USING ERRCODE = 'P1001';
    END IF;

    -- Work out each account's net change on its normal side, then check the
    -- resulting balance. Repeated accounts are combined and checked once.
    FOR v_change IN
        SELECT
            a.id AS account_id,
            a.type AS account_type,
            a.allow_negative,
            a.cached_balance,
            SUM(
                CASE
                    WHEN (a.type IN ('asset', 'expense')
                          AND element->>'direction' = 'debit')
                      OR (a.type IN ('liability', 'income')
                          AND element->>'direction' = 'credit')
                    THEN (element->>'amount')::NUMERIC
                    ELSE -((element->>'amount')::NUMERIC)
                END
            ) AS net_change
        FROM ledger.accounts AS a
        JOIN jsonb_array_elements(p_legs) AS legs(element)
          ON a.id = (element->>'account_id')::NUMERIC::BIGINT
        GROUP BY a.id, a.type, a.allow_negative, a.cached_balance
        ORDER BY a.id
    LOOP
        IF NOT v_change.allow_negative
           AND v_change.cached_balance::NUMERIC + v_change.net_change < 0 THEN
            RAISE EXCEPTION 'account % has insufficient funds: balance %, change %',
                v_change.account_id, v_change.cached_balance, v_change.net_change
                USING ERRCODE = 'P1001';
        END IF;

        IF v_change.cached_balance::NUMERIC + v_change.net_change
           > 9223372036854775807 THEN
            RAISE EXCEPTION 'account % balance would exceed BIGINT capacity',
                v_change.account_id
                USING ERRCODE = 'P1001';
        END IF;

        IF v_change.cached_balance::NUMERIC + v_change.net_change
           < -9223372036854775808 THEN
            RAISE EXCEPTION 'account % balance would fall below BIGINT capacity',
                v_change.account_id
                USING ERRCODE = 'P1001';
        END IF;
    END LOOP;

    INSERT INTO ledger.transactions (
        type, reverses_transaction_id, metadata, idempotency_key
    )
    VALUES (
        p_type, p_reverses_transaction_id, p_metadata, p_idempotency_key
    )
    RETURNING id, created_at INTO v_transaction_id, v_created_at;

    INSERT INTO ledger.ledger_entries (
        transaction_id, account_id, direction, amount, created_at
    )
    SELECT
        v_transaction_id,
        (element->>'account_id')::NUMERIC::BIGINT,
        (element->>'direction')::ledger.ledger_direction,
        (element->>'amount')::NUMERIC::BIGINT,
        v_created_at
    FROM jsonb_array_elements(p_legs) AS legs(element);

    -- Apply each account's already-checked net balance change exactly once.
    FOR v_change IN
        SELECT
            a.id AS account_id,
            SUM(
                CASE
                    WHEN (a.type IN ('asset', 'expense')
                          AND element->>'direction' = 'debit')
                      OR (a.type IN ('liability', 'income')
                          AND element->>'direction' = 'credit')
                    THEN (element->>'amount')::NUMERIC
                    ELSE -((element->>'amount')::NUMERIC)
                END
            ) AS net_change
        FROM ledger.accounts AS a
        JOIN jsonb_array_elements(p_legs) AS legs(element)
          ON a.id = (element->>'account_id')::NUMERIC::BIGINT
        GROUP BY a.id, a.type
        ORDER BY a.id
    LOOP
        UPDATE ledger.accounts
        SET cached_balance = (cached_balance::NUMERIC + v_change.net_change)::BIGINT
        WHERE id = v_change.account_id;
    END LOOP;

    RETURN v_transaction_id;
END;
$$;
