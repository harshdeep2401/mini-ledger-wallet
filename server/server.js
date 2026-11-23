// Starts the API:  npm run api   (default http://localhost:3001)
// In production-style use it also serves the built React app from client/dist.
import { existsSync } from 'node:fs';
import path from 'node:path';
import express from 'express';
import { app } from './app.js';
import { pools } from './db.js';

const clientDist = path.join(import.meta.dirname, '..', 'client', 'dist');
if (existsSync(clientDist)) {
  app.use(express.static(clientDist));
  app.get(/^\/(?!api\/).*/, (req, res) => res.sendFile(path.join(clientDist, 'index.html')));
}

const port = Number(process.env.API_PORT ?? 3001);
app.listen(port, () => {
  console.log(`Ledger API listening on http://localhost:${port}`);
  for (const [name, pool] of Object.entries(pools)) {
    if (!pool) console.warn(`  warning: ${name} login is not configured (run npm run server:setup-logins)`);
  }
});
