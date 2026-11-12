import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { Header, useApp } from '../App';
import { ago, call, CATEGORIES } from '../lib/api';
import { chime, listen } from '../lib/live';
import JoinAgency from './JoinAgency';

export default function Respond() {
  const { me } = useApp();
  const isResponder = me && ['responder', 'agency_admin'].includes(me.role) && me.agency?.status === 'active';
  const [queue, setQueue] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState('');
  const seen = useRef(new Set());
  const first = useRef(true);

  const load = useCallback(async () => {
    try {
      const q = await call('securelink_queue');
      const fresh = q.filter((i) => i.status === 'active' && !seen.current.has(i.id));
      q.forEach((i) => seen.current.add(i.id));
      if (!first.current && fresh.length) { chime(); document.title = `(${fresh.length}) New alert · SecureLink`; }
      first.current = false;
      setQueue(q); setError('');
    } catch (e) { setError(e.message); }
  }, []);

  useEffect(() => {
    if (!isResponder) return undefined;
    load();
    const t = setInterval(load, 20_000);
    const stop = listen(`sl:agency:${me.agency.id}`, ['incident', 'escalated', 'signal_lost'], () => load());
    const onFocus = () => { document.title = 'SecureLink'; };
    window.addEventListener('focus', onFocus);
    return () => { clearInterval(t); stop(); window.removeEventListener('focus', onFocus); };
  }, [isResponder, me?.agency?.id, load]);

  const take = async (id) => {
    setBusy(id);
    try { await call('securelink_acknowledge', { p_incident: id }); await load(); }
    catch (e) { setError(e.message); await load(); }
    finally { setBusy(''); }
  };

  if (!isResponder) {
    return (<><Header back="/" /><main className="page"><h1 className="h">Responder console</h1>
      <p className="muted">For police, fire, ambulance and road-safety teams working with SecureLink. Ask your agency's SecureLink lead for an invite code.</p>
      <JoinAgency /></main></>);
  }

  const open = (queue || []).filter((i) => i.status === 'active');
  const mine = (queue || []).filter((i) => i.status === 'acknowledged');

  return (
    <>
      <Header back="/" />
      <main className="page wide">
        <div className="row-between"><h1 className="h">{me.agency.name}</h1><span className="live-dot">Live</span></div>
        <p className="muted small">Keep this page open on duty. New alerts sound and vibrate (tap the page once so your browser allows sound).</p>
        {error ? <p className="err">{error}</p> : null}
        {queue === null ? <div className="spinner" /> : null}

        {queue && open.length === 0 && mine.length === 0 ? <div className="card empty">No open alerts for your agency right now.</div> : null}

        {mine.length ? <><h2 className="sub">Taken by your agency</h2><ul className="queue">{mine.map((i) => <Row key={i.id} i={i} />)}</ul></> : null}
        {open.length ? <><h2 className="sub">Waiting for a responder</h2>
          <ul className="queue">{open.map((i) => <Row key={i.id} i={i} action={<button type="button" className="btn primary" disabled={busy === i.id} onClick={() => take(i.id)}>{busy === i.id ? 'Taking…' : 'Take it'}</button>} />)}</ul></> : null}
      </main>
    </>
  );
}

function Row({ i, action }) {
  const cat = CATEGORIES[i.category] || CATEGORIES.general;
  return (
    <li className={`qrow cat-${i.category}`}>
      <div className="qmain">
        <b>{cat.long}</b>
        <span className="muted small">{i.distanceKm != null ? `${Number(i.distanceKm).toFixed(1)} km from base · ` : ''}raised {ago(i.startedAt)}</span>
        <span className="flags">
          {i.blind ? <em className="flag warn">No location yet</em> : null}
          {i.signalLost ? <em className="flag warn">Signal lost · last seen {ago(i.lastSeenAt)}</em> : null}
          {i.escalations > 0 ? <em className="flag">Escalated ×{i.escalations}</em> : null}
          {i.mine ? <em className="flag ok">Yours</em> : null}
        </span>
        {i.note ? <span className="note">“{i.note}”</span> : null}
      </div>
      <div className="qact">{action}<Link to={`/respond/${i.id}`} className="btn ghost">Open</Link></div>
    </li>
  );
}
