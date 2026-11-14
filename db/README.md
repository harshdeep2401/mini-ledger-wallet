# Database layer

This is the core of the project. The project author writes the SQL implementation
here by hand, including the schema, constraints, triggers, and PL/pgSQL
functions. Keep application business logic in PostgreSQL and use the API only
to call those functions.

The target database is hosted on Neon. Connect to that database with a
PostgreSQL client such as `psql`; a local PostgreSQL server is optional. Keep
the Neon connection string in a local `.env` file and out of Git.

Use the numbered file order from `IMPLEMENTATION-PLAN.md` as the database work
takes shape. No database implementation files have been added yet.
