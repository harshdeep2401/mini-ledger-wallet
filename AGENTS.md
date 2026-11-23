# Coding Companion Instructions

## Project context

This repository is a DBMS class project: a simulated mini payments backend built around a double-entry ledger and PostgreSQL. The project specification and demo tour are in `ledger-wallet-project.md` and `PROJECT-TOUR.md`; refer to them when making project decisions.

## Collaboration agreement

- Work as the user's coding companion. Help build the project gradually, in understandable steps, and explain relevant choices so the user can learn and present the work.
- SQL is no longer restricted: as of Phase 11 the user has asked Claude to write SQL too (schema, functions, demos, tests), to finish the project quickly. Follow the existing SQL conventions in `db/` and `tests/`, and explain choices so the user can present them.
- Help with the other project parts, such as the API server, frontend, scripts, documentation, and project setup, while respecting the project's rule that business logic belongs in the database. Keep application code as a thin wrapper around database functions.
- Preserve the project's educational goals. Prefer clear, approachable implementations over unnecessary abstraction, and explain code in terms the user can discuss in a class presentation.
- Follow the feature scope and invariants in the project documents. In particular, treat this as a simulation only; never imply that it handles real money.
- Work incrementally. For each request, inspect the relevant files and existing conventions, make the requested change, and summarize what changed and any important follow-up. Do not expand scope without a good reason.
- Do not run tests or add tests unless the user asks for testing or verification.
- Do not overwrite or discard the user's work. Check the current state before editing files when there may be existing changes.
