import { useEffect, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { finishPrimersSignIn } from '../lib/primersId';

export default function AuthReturn() {
  const navigate = useNavigate();
  const ran = useRef(false);
  const [error, setError] = useState('');
  useEffect(() => {
    if (ran.current) return; // the code works once
    ran.current = true;
    finishPrimersSignIn().then((to) => navigate(to, { replace: true })).catch((e) => setError(e.message));
  }, [navigate]);
  if (!error) return <div className="center"><div className="spinner" /><p className="muted">Signing you in…</p></div>;
  return (
    <div className="center"><div className="card narrow"><h1 className="h">Couldn't sign you in</h1><p>{error}</p>
      <Link to="/" className="btn primary">Back</Link><a className="call112" href="tel:112">In danger? Call 112</a></div></div>
  );
}
