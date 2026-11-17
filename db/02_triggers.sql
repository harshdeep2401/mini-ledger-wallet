-- create index on ledger_entries(transaction_id) for faster lookups
create index idx_ledger_entries_trxn
on ledger_entries(transaction_id);


-- INVARIANT: history is append-only.
-- Shared by the UPDATE/DELETE/TRUNCATE triggers on ledger_entries and
-- transactions; it rejects the change so mistakes are fixed with a reversing
-- transaction instead.
create or replace function prevent_changes()
returns trigger as $$
begin
    raise exception
        'ledger history is append-only; post a reversing transaction instead'
        using errcode = 'P1001';
end;
$$ language plpgsql;

create trigger prevent_ledger_changes
before update or delete
on ledger_entries
for each row
execute function prevent_changes();

create trigger prevent_ledger_truncate
before truncate
on ledger_entries
for each statement
execute function prevent_changes();

create trigger prevent_transaction_changes
before update or delete
on transactions
for each row
execute function prevent_changes();

create trigger prevent_transaction_truncate
before truncate
on transactions
for each statement
execute function prevent_changes();


-- INVARIANT: every transaction is non-empty and balanced (debits = credits).
-- Shared by the deferred constraint triggers on ledger_entries and
-- transactions, so it runs at COMMIT. The check on transactions catches empty
-- transactions; the check on ledger_entries catches extra legs added later.

CREATE OR REPLACE FUNCTION balance_check()
RETURNS trigger AS $$
DECLARE
    checked_transaction_id BIGINT;
    entry_count BIGINT;
    debit_total NUMERIC;
    credit_total NUMERIC;
BEGIN
    IF TG_TABLE_NAME = 'transactions' THEN
        checked_transaction_id := NEW.id;
    ELSE
        checked_transaction_id := NEW.transaction_id;
    END IF;

    SELECT
        COUNT(*),
        COALESCE(SUM(amount) FILTER (WHERE direction = 'debit'), 0),
        COALESCE(SUM(amount) FILTER (WHERE direction = 'credit'), 0)
    INTO entry_count, debit_total, credit_total
    FROM ledger_entries
    WHERE transaction_id = checked_transaction_id;

    IF entry_count = 0 THEN
        RAISE EXCEPTION
            'transaction % has no ledger entries',
            checked_transaction_id
            USING ERRCODE = 'P1001';
    ELSIF debit_total <> credit_total THEN
        RAISE EXCEPTION
            'transaction % is unbalanced: debits % != credits %',
            checked_transaction_id, debit_total, credit_total
            USING ERRCODE = 'P1001';
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

create CONSTRAINT trigger balance_ledger_check
-- check after insert because we have made the db append only
after insert
on ledger_entries
deferrable initially deferred
for each row
execute function balance_check();

create constraint trigger balance_transaction_check
after insert
on transactions
deferrable initially deferred
for each row
execute function balance_check();


-- INVARIANT: no postings (debit or credit) to a frozen or closed account.
-- Runs BEFORE INSERT on ledger_entries; account status is the only switch.
create or replace function status_guard()
returns trigger as $$
declare
    acc_status account_status;
begin
    select status
    into acc_status
    from accounts
    where id = new.account_id;

    if acc_status in ('frozen', 'closed') then
        raise exception
            'account % cannot receive postings because its status is %',
            new.account_id, acc_status
            using errcode = 'P1001';
    end if;
    return new;
end;
$$ language plpgsql;

create trigger block_inactive_account_postings
before insert
on ledger_entries
for each row
execute function status_guard();
