-- Deliberately BROKEN functions for the Phase 11 concurrency demos (D13).
-- They live in their own `demo` schema and are installed only by
-- `npm run demo:setup`, never by db:reset or db:apply. Nothing in production
-- code calls them, and no role except ledger_owner can execute them.
-- Each one takes a pause (seconds) between its two critical steps so the
-- race is reproducible every time instead of depending on lucky timing.
-- Run as ledger_owner (the setup script does SET ROLE ledger_owner first).

CREATE SCHEMA IF NOT EXISTS demo;
REVOKE ALL ON SCHEMA demo FROM PUBLIC;


-- BROKEN ON PURPOSE (double-spend): checks the balance WITHOUT locking the
-- wallet row, waits, then posts. Two concurrent calls both see the old
-- balance, both pass the check, and both withdraw. The real withdraw() locks
-- the account first (post_transaction), so the second caller sees the new
-- balance and is refused.
CREATE OR REPLACE FUNCTION demo.withdraw_unsafe(
    p_wallet_account_id BIGINT,
    p_amount BIGINT,
    p_pause_seconds DOUBLE PRECISION DEFAULT 1
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
DECLARE
    v_balance BIGINT;
    v_bank_account_id BIGINT;
    v_transaction_id BIGINT;
    v_created_at TIMESTAMPTZ;
BEGIN
    -- BUG 1: plain SELECT, no FOR UPDATE, so nothing stops a second reader.
    SELECT cached_balance INTO v_balance
    FROM ledger.accounts
    WHERE id = p_wallet_account_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'account % does not exist', p_wallet_account_id
            USING ERRCODE = 'P1001';
    END IF;

    IF v_balance < p_amount THEN
        RAISE EXCEPTION 'account % has insufficient funds: balance %, change %',
            p_wallet_account_id, v_balance, -p_amount
            USING ERRCODE = 'P1001';
    END IF;

    -- The window in which the other caller can slip in.
    PERFORM pg_sleep(p_pause_seconds);

    SELECT id INTO v_bank_account_id
    FROM ledger.accounts
    WHERE code = 'BANK' AND user_id IS NULL;

    INSERT INTO ledger.transactions (type, metadata)
    VALUES ('withdrawal', jsonb_build_object('demo', 'unsafe'))
    RETURNING id, created_at INTO v_transaction_id, v_created_at;

    INSERT INTO ledger.ledger_entries (
        transaction_id, account_id, direction, amount, created_at
    )
    VALUES
        (v_transaction_id, p_wallet_account_id, 'debit',  p_amount, v_created_at),
        (v_transaction_id, v_bank_account_id,   'credit', p_amount, v_created_at);

    -- BUG 2: the decision above used a stale balance, so this can go negative.
    UPDATE ledger.accounts
    SET cached_balance = cached_balance - p_amount
    WHERE id = p_wallet_account_id;

    UPDATE ledger.accounts
    SET cached_balance = cached_balance - p_amount
    WHERE id = v_bank_account_id;

    RETURN v_transaction_id;
END;
$$;


-- BROKEN ON PURPOSE (deadlock): locks the sender, waits, then locks the
-- recipient, in the order the caller gave. A->B and B->A each hold one lock
-- and wait for the other, so PostgreSQL has to abort one (SQLSTATE 40P01).
-- The real transfer() and post_transaction() lock accounts in ascending id
-- order, so two opposite transfers just queue up.
-- No fee leg: the demo is about lock order, not fees.
CREATE OR REPLACE FUNCTION demo.transfer_unordered(
    p_sender_account_id BIGINT,
    p_recipient_account_id BIGINT,
    p_amount BIGINT,
    p_pause_seconds DOUBLE PRECISION DEFAULT 1
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, ledger, pg_temp
AS $$
BEGIN
    PERFORM 1 FROM ledger.accounts WHERE id = p_sender_account_id FOR UPDATE;

    PERFORM pg_sleep(p_pause_seconds);

    -- BUG: lock order depends on who the sender is, not on account id.
    PERFORM 1 FROM ledger.accounts WHERE id = p_recipient_account_id FOR UPDATE;

    RETURN ledger.post_transaction(
        p_type => 'transfer'::ledger.transaction_type,
        p_legs => jsonb_build_array(
            jsonb_build_object('account_id', p_sender_account_id,
                               'direction', 'debit', 'amount', p_amount),
            jsonb_build_object('account_id', p_recipient_account_id,
                               'direction', 'credit', 'amount', p_amount)
        ),
        p_metadata => jsonb_build_object('demo', 'unordered')
    );
END;
$$;


-- Closed by default: only ledger_owner (and members) can run these.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA demo FROM PUBLIC;
