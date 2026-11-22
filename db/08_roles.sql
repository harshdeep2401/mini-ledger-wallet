-- Role map:
--   ledger_owner     owns ledger objects; no day-to-day login.
--   ledger_app       login role for the API; may call only user-facing money and read functions.
--   ledger_reporting login for read functions and reconciliation only.
--   ledger_admin     login for freeze/unfreeze and reconciliation only.
-- None of these capability roles receives direct table privileges.
-- Set ledger_app's password separately in Neon, then keep its URL in .env.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ledger_owner') THEN
        CREATE ROLE ledger_owner NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ledger_app') THEN
        CREATE ROLE ledger_app LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ledger_reporting') THEN
        CREATE ROLE ledger_reporting LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'ledger_admin') THEN
        CREATE ROLE ledger_admin LOGIN;
    END IF;
END;
$$;

ALTER ROLE ledger_owner NOLOGIN NOCREATEDB NOCREATEROLE;
ALTER ROLE ledger_app LOGIN NOCREATEDB NOCREATEROLE;
ALTER ROLE ledger_reporting LOGIN NOCREATEDB NOCREATEROLE;
ALTER ROLE ledger_admin LOGIN NOCREATEDB NOCREATEROLE;

-- The migration login needs owner membership for safe schema reset and role tests.
-- It also needs membership in capability roles to SET LOCAL ROLE during tests.
DO $$
DECLARE
    v_login_role TEXT := SESSION_USER;
BEGIN
    IF v_login_role <> 'ledger_owner' THEN
        EXECUTE format('GRANT ledger_owner TO %I', v_login_role);
    END IF;
    IF v_login_role <> 'ledger_app' THEN
        EXECUTE format('GRANT ledger_app TO %I', v_login_role);
    END IF;
    IF v_login_role <> 'ledger_reporting' THEN
        EXECUTE format('GRANT ledger_reporting TO %I', v_login_role);
    END IF;
    IF v_login_role <> 'ledger_admin' THEN
        EXECUTE format('GRANT ledger_admin TO %I', v_login_role);
    END IF;
END;
$$;

-- Close existing access before assigning the objects to their non-login owner.
REVOKE ALL ON SCHEMA ledger FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA ledger FROM PUBLIC, ledger_app, ledger_reporting, ledger_admin;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA ledger FROM PUBLIC, ledger_app, ledger_reporting, ledger_admin;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA ledger FROM PUBLIC, ledger_app, ledger_reporting, ledger_admin;

-- PostgreSQL requires the new schema owner to be able to create schemas in
-- the database when ownership changes. ledger_owner is trusted and NOLOGIN.
DO $$
BEGIN
    EXECUTE format('GRANT CREATE ON DATABASE %I TO ledger_owner', CURRENT_DATABASE());
END;
$$;

ALTER SCHEMA ledger OWNER TO ledger_owner;

-- Existing objects were created by the migration login in phases 1–8.
-- Transfer them explicitly; REASSIGN OWNED is avoided because it can affect
-- unrelated objects owned by the migration login in the same database.
DO $$
DECLARE
    v_object RECORD;
BEGIN
    FOR v_object IN
        SELECT c.relname
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = 'ledger'
          AND c.relkind IN ('r', 'p')
    LOOP
        EXECUTE format('ALTER TABLE ledger.%I OWNER TO ledger_owner', v_object.relname);
    END LOOP;

    FOR v_object IN
        SELECT c.relname
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = 'ledger'
          AND c.relkind = 'S'
    LOOP
        EXECUTE format('ALTER SEQUENCE ledger.%I OWNER TO ledger_owner', v_object.relname);
    END LOOP;

    FOR v_object IN
        SELECT t.typname
        FROM pg_catalog.pg_type AS t
        JOIN pg_catalog.pg_namespace AS n ON n.oid = t.typnamespace
        WHERE n.nspname = 'ledger'
          AND t.typtype = 'e'
    LOOP
        EXECUTE format('ALTER TYPE ledger.%I OWNER TO ledger_owner', v_object.typname);
    END LOOP;

    FOR v_object IN
        SELECT p.oid::pg_catalog.regprocedure AS signature
        FROM pg_catalog.pg_proc AS p
        JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'ledger'
    LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO ledger_owner', v_object.signature);
    END LOOP;
END;
$$;

-- Every function starts as SECURITY INVOKER. Only the listed public API
-- functions below are promoted to SECURITY DEFINER.
DO $$
DECLARE
    v_function RECORD;
BEGIN
    FOR v_function IN
        SELECT p.oid::pg_catalog.regprocedure AS signature
        FROM pg_catalog.pg_proc AS p
        JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'ledger'
    LOOP
        EXECUTE format('ALTER FUNCTION %s SECURITY INVOKER', v_function.signature);
    END LOOP;
END;
$$;

-- Public operations run as the non-login owner. pg_catalog is first and all
-- project objects inside their bodies are schema-qualified.
ALTER FUNCTION ledger.create_user_with_wallet(TEXT, TEXT) SECURITY DEFINER;
ALTER FUNCTION ledger.create_user_with_wallet(TEXT, TEXT) SET search_path TO pg_catalog, ledger, pg_temp;
ALTER FUNCTION ledger.top_up(BIGINT, BIGINT, TEXT) SECURITY DEFINER;
ALTER FUNCTION ledger.top_up(BIGINT, BIGINT, TEXT) SET search_path TO pg_catalog, ledger, pg_temp;
ALTER FUNCTION ledger.withdraw(BIGINT, BIGINT, TEXT) SECURITY DEFINER;
ALTER FUNCTION ledger.withdraw(BIGINT, BIGINT, TEXT) SET search_path TO pg_catalog, ledger, pg_temp;
ALTER FUNCTION ledger.transfer(BIGINT, BIGINT, BIGINT, TEXT) SECURITY DEFINER;
ALTER FUNCTION ledger.transfer(BIGINT, BIGINT, BIGINT, TEXT) SET search_path TO pg_catalog, ledger, pg_temp;
ALTER FUNCTION ledger.refund(BIGINT, BIGINT, TEXT) SECURITY DEFINER;
ALTER FUNCTION ledger.refund(BIGINT, BIGINT, TEXT) SET search_path TO pg_catalog, ledger, pg_temp;
ALTER FUNCTION ledger.get_balance(BIGINT) SECURITY DEFINER;
ALTER FUNCTION ledger.get_balance(BIGINT) SET search_path TO pg_catalog, ledger, pg_temp;
ALTER FUNCTION ledger.get_history(BIGINT, TIMESTAMPTZ, BIGINT, INTEGER) SECURITY DEFINER;
ALTER FUNCTION ledger.get_history(BIGINT, TIMESTAMPTZ, BIGINT, INTEGER) SET search_path TO pg_catalog, ledger, pg_temp;
ALTER FUNCTION ledger.freeze_account(BIGINT) SECURITY DEFINER;
ALTER FUNCTION ledger.freeze_account(BIGINT) SET search_path TO pg_catalog, ledger, pg_temp;
ALTER FUNCTION ledger.unfreeze_account(BIGINT) SECURITY DEFINER;
ALTER FUNCTION ledger.unfreeze_account(BIGINT) SET search_path TO pg_catalog, ledger, pg_temp;
ALTER FUNCTION ledger.reconciliation_issues() SECURITY DEFINER;
ALTER FUNCTION ledger.reconciliation_issues() SET search_path TO pg_catalog, ledger, pg_temp;
ALTER FUNCTION ledger.reconciliation_summary() SECURITY DEFINER;
ALTER FUNCTION ledger.reconciliation_summary() SET search_path TO pg_catalog, ledger, pg_temp;

-- A newly created function is closed by default, even before its explicit grant.
ALTER DEFAULT PRIVILEGES FOR ROLE ledger_owner
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE ledger_owner IN SCHEMA ledger
    REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE ledger_owner IN SCHEMA ledger
    REVOKE ALL ON SEQUENCES FROM PUBLIC;

-- Also close future functions created by the migration login, since reset and
-- later migration files may create objects before switching to ledger_owner.
DO $$
DECLARE
    v_login_role TEXT := SESSION_USER;
BEGIN
    IF v_login_role <> 'ledger_owner' THEN
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC',
            v_login_role
        );
    END IF;
END;
$$;

-- Prefer SET ROLE ledger_owner in future migrations; this default also keeps
-- functions created directly by the trusted migration login closed to PUBLIC.

GRANT USAGE ON SCHEMA ledger TO ledger_app, ledger_reporting, ledger_admin;
GRANT USAGE ON TYPE ledger.transaction_type, ledger.ledger_direction TO ledger_app, ledger_reporting;

-- Application API: includes fee quoting; no account status changes or reconciliation internals.
GRANT EXECUTE ON FUNCTION ledger.create_user_with_wallet(TEXT, TEXT) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.top_up(BIGINT, BIGINT, TEXT) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.withdraw(BIGINT, BIGINT, TEXT) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.transfer(BIGINT, BIGINT, BIGINT, TEXT) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.refund(BIGINT, BIGINT, TEXT) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.get_balance(BIGINT) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.get_history(BIGINT, TIMESTAMPTZ, BIGINT, INTEGER) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.calculate_fee(BIGINT) TO ledger_app;

-- Reporting: reads and audit results only.
GRANT EXECUTE ON FUNCTION ledger.get_balance(BIGINT) TO ledger_reporting;
GRANT EXECUTE ON FUNCTION ledger.get_history(BIGINT, TIMESTAMPTZ, BIGINT, INTEGER) TO ledger_reporting;
GRANT EXECUTE ON FUNCTION ledger.reconciliation_issues() TO ledger_reporting;
GRANT EXECUTE ON FUNCTION ledger.reconciliation_summary() TO ledger_reporting;

-- Admin: operational account status changes and reconciliation only.
GRANT EXECUTE ON FUNCTION ledger.freeze_account(BIGINT) TO ledger_admin;
GRANT EXECUTE ON FUNCTION ledger.unfreeze_account(BIGINT) TO ledger_admin;
GRANT EXECUTE ON FUNCTION ledger.reconciliation_issues() TO ledger_admin;
GRANT EXECUTE ON FUNCTION ledger.reconciliation_summary() TO ledger_admin;

-- ledger_app's LOGIN role has no password in source control. Set it out of band
-- in Neon (ALTER ROLE ledger_app WITH PASSWORD '...') and store its URL in .env.
-- Set ledger_reporting and ledger_admin passwords out of band if they will log in.
