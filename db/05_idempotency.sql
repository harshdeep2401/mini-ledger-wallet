-- Idempotency records live in the same transaction as the money movement.
-- A failed operation rolls back its key row; successful keys are retained so
-- a retry cannot post the same request twice.

CREATE TABLE ledger.idempotency_keys (
    idempotency_key TEXT PRIMARY KEY,
    request_fingerprint BYTEA NOT NULL,
    transaction_id BIGINT NOT NULL
        REFERENCES ledger.transactions(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT idempotency_keys_key_length_check
        CHECK (length(btrim(idempotency_key)) BETWEEN 1 AND 200),
    CONSTRAINT idempotency_keys_fingerprint_length_check
        CHECK (octet_length(request_fingerprint) = 32)
);

-- INVARIANT: a request fingerprint includes its operation name and all
-- outcome-changing arguments. jsonb normalizes object-key order before hashing.
-- The idempotency key itself is deliberately not part of the fingerprint.
CREATE OR REPLACE FUNCTION ledger.idempotency_fingerprint(
    p_operation TEXT,
    p_arguments JSONB
)
RETURNS BYTEA
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_request JSONB;
BEGIN
    IF p_operation IS NULL OR length(btrim(p_operation)) = 0 THEN
        RAISE EXCEPTION 'idempotency operation name is required'
            USING ERRCODE = 'P1001';
    END IF;

    IF p_arguments IS NULL OR jsonb_typeof(p_arguments) <> 'object' THEN
        RAISE EXCEPTION 'idempotency arguments must be a JSON object'
            USING ERRCODE = 'P1001';
    END IF;

    v_request := jsonb_build_object(
        'operation', p_operation,
        'arguments', p_arguments
    );

    RETURN sha256(convert_to(v_request::TEXT, 'UTF8'));
END;
$$;


-- INVARIANT: acquire a transaction-scoped advisory lock before checking the
-- stored key. A competing request for the same key fails fast; a hash collision
-- between different keys only causes harmless extra serialization.
-- Returns the saved transaction ID for a replay, or NULL for a new request.
CREATE OR REPLACE FUNCTION ledger.check_idempotency(
    p_idempotency_key TEXT,
    p_request_fingerprint BYTEA
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_saved_fingerprint BYTEA;
    v_saved_transaction_id BIGINT;
BEGIN
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'an idempotency key is required'
            USING ERRCODE = 'P1001';
    END IF;

    IF length(btrim(p_idempotency_key)) = 0 OR length(p_idempotency_key) > 200 THEN
        RAISE EXCEPTION 'idempotency key must contain between 1 and 200 characters'
            USING ERRCODE = 'P1001';
    END IF;

    IF p_request_fingerprint IS NULL OR octet_length(p_request_fingerprint) <> 32 THEN
        RAISE EXCEPTION 'idempotency request fingerprint must be a SHA-256 digest'
            USING ERRCODE = 'P1001';
    END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(p_idempotency_key, 0)) THEN
        RAISE EXCEPTION 'request with this idempotency key is already in progress'
            USING ERRCODE = 'P1001';
    END IF;

    SELECT request_fingerprint, transaction_id
    INTO v_saved_fingerprint, v_saved_transaction_id
    FROM ledger.idempotency_keys
    WHERE idempotency_key = p_idempotency_key;

    IF FOUND THEN
        IF v_saved_fingerprint IS DISTINCT FROM p_request_fingerprint THEN
            RAISE EXCEPTION 'idempotency key was already used for a different request'
                USING ERRCODE = 'P1001';
        END IF;

        RETURN v_saved_transaction_id;
    END IF;

    -- The caller holds the advisory transaction lock until it records the key
    -- or the transaction ends. New keys are recorded only after posting succeeds.
    RETURN NULL;
END;
$$;


-- INVARIANT: record only a successful money movement. The transaction and
-- this row commit or roll back together, so failed operations leave no key.
CREATE OR REPLACE FUNCTION ledger.record_idempotency(
    p_idempotency_key TEXT,
    p_request_fingerprint BYTEA,
    p_transaction_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_idempotency_key IS NULL
       OR length(btrim(p_idempotency_key)) = 0
       OR length(p_idempotency_key) > 200 THEN
        RAISE EXCEPTION 'idempotency key must contain between 1 and 200 characters'
            USING ERRCODE = 'P1001';
    END IF;

    IF p_request_fingerprint IS NULL OR octet_length(p_request_fingerprint) <> 32 THEN
        RAISE EXCEPTION 'idempotency request fingerprint must be a SHA-256 digest'
            USING ERRCODE = 'P1001';
    END IF;

    IF p_transaction_id IS NULL OR NOT EXISTS (
        SELECT 1
        FROM ledger.transactions
        WHERE id = p_transaction_id
          AND idempotency_key = p_idempotency_key
    ) THEN
        RAISE EXCEPTION 'transaction % was not created with idempotency key %',
            p_transaction_id, p_idempotency_key
            USING ERRCODE = 'P1001';
    END IF;

    INSERT INTO ledger.idempotency_keys (
        idempotency_key, request_fingerprint, transaction_id
    )
    VALUES (
        p_idempotency_key, p_request_fingerprint, p_transaction_id
    );
END;
$$;


-- Idempotency records are permanent and append-only: deleting one would let a
-- retry post the same request again. prevent_changes() is shared with the ledger.
CREATE TRIGGER prevent_idempotency_key_changes
BEFORE UPDATE OR DELETE
ON ledger.idempotency_keys
FOR EACH ROW
EXECUTE FUNCTION ledger.prevent_changes();

CREATE TRIGGER prevent_idempotency_key_truncate
BEFORE TRUNCATE
ON ledger.idempotency_keys
FOR EACH STATEMENT
EXECUTE FUNCTION ledger.prevent_changes();
