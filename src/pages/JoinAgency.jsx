import { useState } from 'react';
import { useApp } from '../App';
import { call } from '../lib/api';

export default function JoinAgency() {
  const { refreshMe } = useApp();
  const [code, setCode] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  const submit = async (e) => {
    e.preventDefault(); setBusy(true); setMsg('');
    try { const r = await call('securelink_join', { p_code: code }); setMsg(`You joined ${r.agency}.`); setCode(''); await refreshMe(); }
    catch (err) { setMsg(err.message); }
    finally { setBusy(false); }
  };
  return (
    <form className="card" onSubmit={submit}>
      <label htmlFor="code">Agency invite code</label>
      <input id="code" value={code} onChange={(e) => setCode(e.target.value.toUpperCase())} placeholder="XXXX-XXXX-XXXX" autoComplete="off" spellCheck="false" maxLength={20} required />
      <button type="submit" className="btn primary" disabled={busy || code.replace(/[^A-Z0-9]/g, '').length < 12}>{busy ? 'Checking…' : 'Join agency'}</button>
      {msg ? <p className="small" role="status">{msg}</p> : null}
    </form>
  );
}
