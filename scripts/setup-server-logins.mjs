// One-time setup of the API's database logins.
//   npm run server:setup-logins
//
// Gives ledger_app and ledger_admin a random password (set with ALTER ROLE) and writes
// APP_DATABASE_URL and ADMIN_DATABASE_URL into .env. Passwords are never printed and .env
// is git-ignored. Run it again with --rotate to replace existing passwords.
import { randomBytes } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import pg from 'pg';

const ENV_FILE = path.join(import.meta.dirname, '..', '.env');
const rotate = process.argv.includes('--rotate');
const roles = [
  { role: 'ledger_app', variable: 'APP_DATABASE_URL' },
  { role: 'ledger_admin', variable: 'ADMIN_DATABASE_URL' },
];

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL is not set. Add it to the .env file in the project folder.');
  process.exit(1);
}

let envText = await readFile(ENV_FILE, 'utf8');
const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();

try {
  for (const { role, variable } of roles) {
    const exists = new RegExp(`^${variable}=`, 'm').test(envText);
    if (exists && !rotate) {
      console.log(`${variable} already in .env, skipping (use --rotate to replace).`);
      continue;
    }

    // ALTER ROLE cannot take a bind parameter, so the password is written into the
    // statement. It is random hex, so it cannot contain quote characters.
    const password = randomBytes(24).toString('hex');
    await client.query(`ALTER ROLE ${role} PASSWORD '${password}'`);

    const url = new URL(process.env.DATABASE_URL);
    url.username = role;
    url.password = password;
    const line = `${variable}=${url.toString()}`;

    if (exists) {
      envText = envText.replace(new RegExp(`^${variable}=.*$`, 'm'), line);
    } else {
      envText += `${envText.endsWith('\n') ? '' : '\n'}${line}\n`;
    }
    await writeFile(ENV_FILE, envText);
    console.log(`${role}: password set, ${variable} written to .env`);
  }
} catch (error) {
  console.error('Login setup failed:', error.message);
  process.exitCode = 1;
} finally {
  await client.end();
}
