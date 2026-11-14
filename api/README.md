# API server

The API will be a thin wrapper around PostgreSQL functions. Each endpoint
should call one database function and return its result; balance checks, fee
calculations, and ledger rules belong in the database.

Choose the API language and framework after the database function signatures
are clearer. No server code has been added yet.
