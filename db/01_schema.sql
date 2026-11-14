-- All project objects live in this namespace so development reset can remove
-- only this project's objects, not Neon or other database objects.
CREATE SCHEMA IF NOT EXISTS ledger;
SET search_path TO ledger;

-- 1. USERS TABLE

CREATE TABLE users (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(150) NOT NULL UNIQUE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- 2. ENUM TYPES

CREATE TYPE account_type AS ENUM (
    'asset',
    'liability',
    'income',
    'expense'
);

CREATE TYPE account_status AS ENUM (
    'active',
    'frozen',
    'closed'
);

CREATE TYPE transaction_type AS ENUM (
    'topup',
    'transfer',
    'withdrawal',
    'refund'
);

CREATE TYPE ledger_direction AS ENUM (
    'debit',
    'credit'
);


-- 3. ACCOUNTS TABLE

CREATE TABLE accounts (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT UNIQUE,
    code TEXT UNIQUE,
    type account_type NOT NULL,
    currency TEXT NOT NULL DEFAULT 'INR',

    status account_status NOT NULL DEFAULT 'active',
    allow_negative BOOLEAN NOT NULL DEFAULT FALSE,
    cached_balance BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT accounts_user_id_references_users
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT,

    CONSTRAINT accounts_currency_inr_check CHECK (currency = 'INR'),

    CONSTRAINT accounts_user_id_liability_check
        CHECK (user_id IS NULL OR type = 'liability'),

    CONSTRAINT accounts_user_id_code_xor_check
        CHECK (
            (user_id IS NOT NULL AND code IS NULL)
            OR
            (user_id IS NULL AND code IS NOT NULL)
        )
);


-- 4. TRANSACTIONS TABLE

CREATE TABLE transactions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    type transaction_type NOT NULL,
    reverses_transaction_id BIGINT
        REFERENCES transactions(id) ON DELETE RESTRICT,
    idempotency_key TEXT,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT transactions_reverses_transaction_id_refund_check
        CHECK (
            (type = 'refund' AND reverses_transaction_id IS NOT NULL)
            OR
            (type <> 'refund' AND reverses_transaction_id IS NULL)
        ),
    CONSTRAINT transactions_reverses_transaction_id_not_self_check
        CHECK (reverses_transaction_id IS DISTINCT FROM id)
);


-- 5. LEDGER ENTRIES TABLE

CREATE TABLE ledger_entries (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id BIGINT NOT NULL
        REFERENCES transactions(id) ON DELETE RESTRICT,
    account_id BIGINT NOT NULL
        REFERENCES accounts(id) ON DELETE RESTRICT,
    direction ledger_direction NOT NULL,
    amount BIGINT NOT NULL,
    CONSTRAINT ledger_entries_amount_positive_check CHECK (amount > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
