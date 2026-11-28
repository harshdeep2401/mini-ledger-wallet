# Final Demo

## 1. Before the demo

```sh
cd ~/Desktop/mini-ledger-wallet
npm run db:seed:logins
npm run client:build
npm run server
```

Open: http://localhost:3001

## 1a. One time only (before the first demo)

1. Copy the invite code from the `db:seed:logins` output: `invite-________`
2. **Admin** → Sign up → your name → your email → your password → invite code → Create admin account

## 2. Log-ins

| Who | Email | Password |
|---|---|---|
| Admin | harsh@gmail.com | harsh123 |
| User 1 | `riya.demo@mini-ledger.test` | `demo-password` |
| User 2 | `kabir.demo@mini-ledger.test` | `demo-password` |

## 3. Windows

- Window A (normal): Admin
- Window B (private / incognito): User

## 4. Window A: Admin → Demo console

Log in: **Admin** → your admin email / password → **Demo console**

1. **Start here**
2. **Bank → wallet and back** → Next step to the end
3. **Transfer with a fee** → Next step to the end
4. **Refunds** → Next step to the end
5. **Overdraft and frozen accounts** → Next step to the end
6. **Double-click and retries (idempotency)** → Next step to the end
7. **Try to break the ledger** → Next step to the end
8. **Reconciliation catches tampering** → Next step to the end
9. **Concurrency** → Double-spend → Run
10. **Concurrency** → Deadlock → Run
11. **Concurrency** → Idempotency → Run
12. **Performance**

## 5. Window B: User

1. Log in: **Wallet user** → `riya.demo@mini-ledger.test` / `demo-password`
2. **＋ Add money** → `1000` → Add money
3. **↓ Withdraw** → `200` → Withdraw
4. **→ Transfer** → To `Kabir` → `500` → Review payment → Confirm and pay
5. Make another payment → To `Kabir` → `100` → Review payment → Demo: send twice
6. Make another payment → To `Kabir` → `999999` → Review payment → Confirm and pay
7. Log out
8. Log in: **Wallet user** → `kabir.demo@mini-ledger.test` / `demo-password`
9. Recent activity → Riya's ₹500 transfer → **Refund**
10. Log out
11. Log in: **Wallet user** → `riya.demo@mini-ledger.test` / `demo-password`

## 6. Window A: Admin → Dashboard

1. **Dashboard**
2. Traffic simulator → `10 / sec` → **Start**
3. Live transactions → click a **transfer** row
4. Live transactions → click a **refund** row
5. Traffic simulator → **Stop**
6. Wallets → search `kabir` → **Freeze**
7. Window B → **→ Transfer** → To: type `Kabir`
8. Window A → Wallets → search `kabir` → **Unfreeze**
9. Window B → **→ Transfer** → To: type `Kabir`
10. Window A → Ledger check → **Check ledger**

## 7. Window B: Lockout

1. Log out
2. Log in: **Wallet user** → `kabir.demo@mini-ledger.test` / `wrong-pass-1`
3. Repeat step 2 four more times
4. Log in: **Wallet user** → `kabir.demo@mini-ledger.test` / `demo-password`

## 8. Terminal (second window)

```sh
cd ~/Desktop/mini-ledger-wallet
npm run test:db
npm run demo:setup
npm run demo:concurrency
npm run demo:teardown
```

## 9. If needed

| Problem | Command |
|---|---|
| Riya or Kabir locked | `npm run db:seed:logins` |
| Your admin log-in locked | wait 5 minutes |
| Page shows 503 | `npm run server:setup-logins`, then restart `npm run server` |
| Feed shows "reconnecting" | Ctrl+C the server, then `npm run server` |
| Port 3001 busy | `lsof -ti :3001 \| xargs kill`, then `npm run server` |
