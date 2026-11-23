import { useRef, useState } from 'react';

// One idempotency key per user ACTION.
// The same request retried (a double-click, a retry after a network error) reuses its key,
// so the database applies it once. A changed request, or a success, starts a new action.
export function useAction(send) {
  const lastRef = useRef({ signature: null, key: null });
  const [state, setState] = useState({ status: 'idle' });

  async function run(payload) {
    const signature = JSON.stringify(payload);
    if (lastRef.current.signature !== signature) {
      lastRef.current = { signature, key: crypto.randomUUID() };
    }
    const { key } = lastRef.current;
    setState({ status: 'loading' });
    try {
      const result = await send(payload, key);
      lastRef.current = { signature: null, key: null };
      setState({ status: 'done', result, key });
      return result;
    } catch (error) {
      setState({ status: 'error', error: error.message, key });
      return null;
    }
  }

  return { state, run, currentKey: () => lastRef.current.key };
}
