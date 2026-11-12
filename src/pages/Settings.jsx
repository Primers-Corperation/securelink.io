import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Header, useApp } from '../App';
import { sb } from '../lib/supabase';
import { ago, call, CATEGORIES } from '../lib/api';
import JoinAgency from './JoinAgency';

export default function Settings() {
  const { session, me, refreshMe } = useApp();
  const navigate = useNavigate();
  const [history, setHistory] = useState(null);
  const [msg, setMsg] = useState('');
  const [shake, setShake] = useState(() => { try { return localStorage.getItem('securelink-shake') === 'on'; } catch { return false; } });

  useEffect(() => { call('securelink_my_history', { p_limit: 20 }).then(setHistory).catch(() => setHistory([])); }, []);

  const toggleCommunity = async (on) => {
    setMsg('');
    if (!on) { await call('securelink_set_area', {}).catch(() => {}); await refreshMe(); return; }
    navigator.geolocation?.getCurrentPosition(async (p) => {
      try { await call('securelink_set_area', { p_lat: p.coords.latitude, p_lng: p.coords.longitude }); await refreshMe(); }
      catch (e) { setMsg(e.message); }
    }, () => setMsg('Allow location for this site to get alerts about your area.'), { timeout: 20000 });
  };

  const toggleShake = async (on) => {
    setMsg('');
    if (on && typeof DeviceMotionEvent !== 'undefined' && typeof DeviceMotionEvent.requestPermission === 'function') {
      try { if (await DeviceMotionEvent.requestPermission() !== 'granted') { setMsg('Motion access was not allowed.'); return; } }
      catch { setMsg('Motion access was not allowed.'); return; }
    }
    try { localStorage.setItem('securelink-shake', on ? 'on' : 'off'); } catch { /* ignore */ }
    setShake(on);
  };

  const signOut = async () => { await sb.auth.signOut({ scope: 'local' }); navigate('/'); };
  const name = session?.user?.user_metadata?.full_name || session?.user?.email;

  return (
    <>
      <Header back="/" />
      <main className="page">
        <h1 className="h">Settings</h1>
        <section className="card">
          <b>{name}</b>
          <span className="muted small">{session?.user?.email} · signed in with Primers ID</span>
          <div className="row wrap">
            <a className="btn ghost" href="https://id.primersgroup.ng/account" target="_blank" rel="noopener noreferrer">Manage Primers ID</a>
            <button type="button" className="btn ghost" onClick={signOut}>Sign out</button>
          </div>
        </section>

        <section className="card">
          <label className="switch"><input type="checkbox" checked={!!me?.communityAlerts} onChange={(e) => toggleCommunity(e.target.checked)} />
            <span><b>Alerts about my area</b><small>Hear when someone within about 5 km raises an alert. SecureLink stores only a rough area for this, never your exact location.</small></span></label>
          <label className="switch"><input type="checkbox" checked={shake} onChange={(e) => toggleShake(e.target.checked)} />
            <span><b>Shake to alert</b><small>Shake the phone hard three times while SecureLink is open to start an SOS countdown.</small></span></label>
          {msg ? <p className="small err">{msg}</p> : null}
        </section>

        {me?.role === 'citizen' ? <section><h2 className="sub">Work for a responder agency?</h2><JoinAgency /></section> : null}
        {me?.agency ? <section className="card"><b>{me.agency.name}</b><span className="muted small">You are a {me.role === 'agency_admin' ? 'agency admin' : 'responder'}.</span><Link to="/respond" className="btn">Open responder console</Link></section> : null}

        <section>
          <h2 className="sub">Your alerts</h2>
          {history === null ? <div className="spinner" /> : history.length === 0 ? <p className="muted small">You haven't raised any alerts.</p> : (
            <ul className="history">{history.map((h) => (
              <li key={h.id}><Link to={`/alert/${h.id}`}><b>{(CATEGORIES[h.category] || CATEGORIES.general).long}</b><span className="muted small">{ago(h.startedAt)} · {h.status}{h.agency ? ` · ${h.agency}` : ''}</span></Link></li>
            ))}</ul>)}
        </section>
        <p className="fine"><Link to="/privacy">Privacy policy</Link> · SecureLink by Securelink Defence International Limited, a Primers Group company</p>
      </main>
    </>
  );
}
