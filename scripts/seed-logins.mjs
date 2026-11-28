// Demo log-ins, so the user and admin dashboards can be shown straight away.
//   npm run db:seed:logins
//
// SIMULATION ONLY: made-up people with published demo passwords. Runs as the owner
// login and uses internal functions that store bcrypt hashes. Safe to run again: it
// resets these passwords and lock-outs, and prints a NEW single-use admin invite code.
// There is no built-in admin: sign up your own admin in the app with that code.
//
// The log-in users are Riya and Kabir, NOT Alice and Bob: tests/09_seed.sql expects
// Alice and Bob's balances never to change, so they are kept out of the browser demo.
// Riya and Kabir are created with ₹5,000 each the first time (fixed idempotency keys,
// so a re-run never tops them up again).
import { randomBytes } from 'node:crypto';
import pg from 'pg';

const USER_PASSWORD = 'demo-password';
const USERS = [
  { name: 'Riya Demo', email: 'riya.demo@mini-ledger.test' },
  { name: 'Kabir Demo', email: 'kabir.demo@mini-ledger.test' },
];

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL is not set. Add it to the .env file in the project folder.');
  process.exit(1);
}

const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();
try {
  await client.query('BEGIN');

  for (const user of USERS) {
    let { rows } = await client.query('SELECT id FROM ledger.users WHERE email = $1', [user.email]);
    if (rows.length === 0) {
      ({ rows } = await client.query('SELECT ledger.create_user_with_wallet($1, $2) AS id', [user.name, user.email]));
    }
    const userId = rows[0].id;
    await client.query('SELECT ledger.set_password($1, $2)', [userId, USER_PASSWORD]);
    await client.query(
      `SELECT ledger.top_up(a.id, 500000, $2) FROM ledger.accounts AS a WHERE a.user_id = $1`,
      [userId, `demo-login-start-${user.email}`],
    );
  }

  const invite = `invite-${randomBytes(4).toString('hex')}`;
  await client.query('SELECT ledger.create_admin_invite($1)', [invite]);
  await client.query('COMMIT');

  console.log('User log-ins:');
  for (const user of USERS) console.log(`  ${user.email}  password: ${USER_PASSWORD}`);
  console.log(`Admin invite code (single use: Admin → Sign up in the app): ${invite}`);
} catch (error) {
  await client.query('ROLLBACK').catch(() => {});
  console.error('Login seed failed:', error.message);
  process.exitCode = 1;
} finally {
  await client.end();
}
