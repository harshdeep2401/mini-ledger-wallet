# Mini Ledger Wallet

A payments backend where the **database itself** guarantees that money cannot be created, lost, double-spent or silently edited, even if the application code is buggy. It is built around a double-entry ledger in PostgreSQL, with a thin Express server and a React demo console on top.

> **Simulation only.** This project does not handle real money and is not connected to any bank, payment gateway or UPI network.

## How it fits together

```
Browser (React)  →  Express server  →  PostgreSQL (Neon)
   client/            server/              db/
                one DB function            all the rules
                per request
```

- Balances come from immutable debit and credit entries, in integer paise. Every transaction must balance, checked at commit by a deferred trigger.
- The server contains no business logic. Each endpoint opens a transaction, calls exactly one database function and returns the result.
- The server logs in as limited roles (`ledger_app`, `ledger_admin`) that have no access to any table, only to approved functions.
- The UPI layer (VPA, PIN, collect requests) is not part of this project.

## Layout

| Folder | What is in it |
|---|---|
| `db/` | Schema, triggers, posting and operation functions, idempotency, reads, reconciliation, roles |
| `tests/` | SQL tests, run with `npm run test:db` |
| `server/` | Express API (`server/app.js`) and the demo engine (`server/demo/`) |
| `client/` | React app: Wallets, Pay, Ledger check, and the **Demo console** |
| `demos/` | Concurrency demos (broken vs real) and the demo seed |
| `scripts/` | Database apply/reset, seeds, login setup, evidence capture |
| `docs/` | Decisions, invariants, performance, concurrency, ER diagram, demo script |

## Run it

You need a recent Node (built on Node 24) and a PostgreSQL database (this project uses Neon).

```sh
npm install
npm run client:install
```

1. Create `.env` from `.env.example` and set `DATABASE_URL` (the owner connection).
2. Build the database and check it: `npm run db:reset` then `npm run test:db`.
3. Create the server's limited logins: `npm run server:setup-logins`. It writes `APP_DATABASE_URL` and `ADMIN_DATABASE_URL` into `.env` and never prints the passwords.
4. Start the server: `npm run server` (port 3001).
5. Start the client: `npm run client:dev`, then open http://localhost:5173.

For one process instead: `npm run client:build`, then `npm run server` and open http://localhost:3001.

Optional data:
- `npm run db:seed:demo`: Alice and Bob with known balances.
- `npm run db:seed:performance`: about 127,000 transactions, used for the performance evidence (`npm run db:explain`).

## Demo

Open the **Demo console** tab. Each act is a scripted scenario played one step at a time. Every step shows the function called, the input sent, the output returned, the ledger legs, and the balances before and after.

The walk-through, with what to say, is in [`docs/demo-script.md`](docs/demo-script.md).

## Documents

- [`docs/decisions.md`](docs/decisions.md): every design decision
- [`docs/invariants.md`](docs/invariants.md): each guarantee, what enforces it, which test proves it
- [`docs/concurrency.md`](docs/concurrency.md): the race and deadlock demos
- [`docs/performance.md`](docs/performance.md): indexing and pagination measurements
- [`docs/er-diagram.md`](docs/er-diagram.md): the schema
- [`ledger-wallet-project.md`](ledger-wallet-project.md): the specification
