# Mini Ledger Wallet

A DBMS class project: a simulated wallet and payments backend built around a
double-entry ledger in PostgreSQL. The database is responsible for money
movement and its safety rules; the API and frontend will provide a thin demo
interface.

> **Simulation only:** this project does not handle real money or connect to a
> payment gateway.

## Project layout

- `db/` — database work written by the project author: schema, constraints,
  triggers, and functions.
- `api/` — API server that will call the database functions.
- `frontend/` — small UI for demonstrating wallet operations.
- `demos/` — concurrency and performance demonstrations.
- `docs/` — design decisions, diagrams, and project write-ups.
- `ledger-wallet-project.md` — project specification.
- `PROJECT-TOUR.md` — planned demo and presentation guide.
- `IMPLEMENTATION-PLAN.md` — step-by-step database implementation plan.

## Core design

Balances are derived from immutable debit and credit entries, with integer
amounts in paise. Every transaction must balance, and application code should
delegate business rules to PostgreSQL rather than changing balances itself.

## Database setup

The project uses a PostgreSQL database hosted on Neon; a local PostgreSQL
server is not required. Create a Neon project and database, then connect with
`psql` or another PostgreSQL client. Store the connection string in a local
`.env` file, never in source control. The `.gitignore` excludes `.env` files.

## Project notes

See [`ledger-wallet-project.md`](ledger-wallet-project.md) for requirements and
[`PROJECT-TOUR.md`](PROJECT-TOUR.md) for the intended demo flow.
