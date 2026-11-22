-- DEVELOPMENT ONLY: permanently removes this project's schema and its data.
-- Do not run against a database containing data you need to keep.
-- Cluster-wide roles survive schema reset; db/08_roles.sql safely reuses them.
DROP SCHEMA IF EXISTS ledger CASCADE;
