-- Phase 11: the deliberately broken demo functions must never be callable by
-- the application roles. Skipped when `npm run demo:setup` has not been run.
BEGIN;
SET LOCAL search_path TO ledger;

DO $$
DECLARE
    v_role TEXT;
    v_function TEXT;
BEGIN
    IF to_regnamespace('demo') IS NULL THEN
        RAISE NOTICE 'TEST SKIPPED: demo schema is not installed';
        RETURN;
    END IF;

    FOREACH v_role IN ARRAY ARRAY['ledger_app', 'ledger_reporting', 'ledger_admin'] LOOP
        IF has_schema_privilege(v_role, 'demo', 'USAGE') THEN
            RAISE EXCEPTION 'TEST FAILED: % has USAGE on schema demo', v_role;
        END IF;

        FOR v_function IN
            SELECT p.oid::regprocedure::TEXT
            FROM pg_proc AS p
            WHERE p.pronamespace = 'demo'::regnamespace
        LOOP
            IF has_function_privilege(v_role, v_function, 'EXECUTE') THEN
                RAISE EXCEPTION 'TEST FAILED: % can execute %', v_role, v_function;
            END IF;
        END LOOP;
    END LOOP;

    IF has_schema_privilege('public', 'demo', 'USAGE') THEN
        RAISE EXCEPTION 'TEST FAILED: PUBLIC has USAGE on schema demo';
    END IF;

    RAISE NOTICE 'TEST PASSED: demo functions are closed to every application role';
END;
$$;

ROLLBACK;
