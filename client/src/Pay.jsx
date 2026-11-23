import { useState } from 'react';
import { api, formatRupees, rupeesToPaise } from './api.js';
import { useAction } from './useAction.js';
import WalletPicker from './WalletPicker.jsx';

// Steps: choose wallets and amount -> confirm (shows the fee) -> result with a reference.
export default function Pay({ initialSender, onChanged }) {
  const [sender, setSender] = useState(initialSender ?? null);
  const [recipient, setRecipient] = useState(null);
  const senderId = sender?.account_id ?? '';
  const recipientId = recipient?.account_id ?? '';
  const [amountText, setAmountText] = useState('');
  const [step, setStep] = useState('form');
  const [fee, setFee] = useState(null);
  const [error, setError] = useState('');
  const [twice, setTwice] = useState(null);
  const action = useAction(api.transfer);

  const paise = rupeesToPaise(amountText);
  const payload = () => ({ sender_account_id: senderId, recipient_account_id: recipientId, amount: paise });

  async function review(event) {
    event.preventDefault();
    setError('');
    try {
      setFee((await api.fee(paise)).fee);
      setStep('confirm');
    } catch (e) { setError(e.message); }
  }

  async function pay() {
    const result = await action.run(payload());
    if (result) { setStep('result'); onChanged?.(); }
  }

  // Demo: send the SAME request (same key) twice at once. The database applies it once.
  async function payTwice() {
    const key = crypto.randomUUID();
    const results = await Promise.allSettled([api.transfer(payload(), key), api.transfer(payload(), key)]);
    setTwice(results.map((r) => (r.status === 'fulfilled'
      ? `OK, ref #${r.value.transaction_id}`
      : `Refused: ${r.reason.message}`)));
  }

  function again() {
    setStep('form'); setAmountText(''); setTwice(null); setError('');
  }

  return (
    <section className="card narrow">
      <h2>Pay</h2>
      {step === 'form' && (
        <form onSubmit={review}>
          <WalletPicker label="From" value={sender} onChange={setSender} excludeId={recipientId} />
          <WalletPicker label="To" value={recipient} onChange={setRecipient} excludeId={senderId} />
          <label>Amount (₹)
            <input required value={amountText} onChange={(e) => setAmountText(e.target.value)} placeholder="500.00" />
          </label>
          {amountText && paise === null && <p className="error">Enter an amount like 500 or 500.50</p>}
          <button disabled={paise === null || !sender || !recipient}>Review payment</button>
          {error && <p className="error">{error}</p>}
        </form>
      )}

      {step === 'confirm' && (
        <div>
          <p>Pay <strong>{recipient?.name}</strong></p>
          <table><tbody>
            <tr><td>From</td><td>{sender?.name}</td></tr>
            <tr><td>Amount</td><td>{formatRupees(paise)}</td></tr>
            <tr><td>Fee (set by the database)</td><td>{formatRupees(fee)}</td></tr>
            <tr><td>Total debited</td><td><strong>{formatRupees(paise + Number(fee))}</strong></td></tr>
          </tbody></table>
          <div className="actions">
            <button onClick={pay}>Confirm and pay</button>
            <button className="small" onClick={payTwice}>Demo: send twice</button>
            <button className="small" onClick={() => setStep('form')}>Back</button>
          </div>
          {action.state.status === 'error' && <p className="error">{action.state.error}</p>}
          {twice && (
            <div className="note">
              Same idempotency key sent twice at once:
              <ul>{twice.map((line, i) => <li key={i}>{line}</li>)}</ul>
              Only one payment was made.
            </div>
          )}
        </div>
      )}

      {step === 'result' && (
        <div>
          <p className="ok big">Payment successful</p>
          <p>Reference number: <strong>#{action.state.result.transaction_id}</strong></p>
          <p className="muted">{formatRupees(paise)} sent to {recipient?.name}</p>
          <button onClick={again}>Make another payment</button>
        </div>
      )}
    </section>
  );
}
