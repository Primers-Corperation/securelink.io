import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { Header, useApp } from '../App';
import { sb } from '../lib/supabase';
import { ago, call, CATEGORIES } from '../lib/api';
import { listen } from '../lib/live';

export default function Incident() {
  const { id } = useParams();
  const { me } = useApp();
  const navigate = useNavigate();
  const [inc, setInc] = useState(null);
  const [error, setError] = useState('');
  const [outcome, setOutcome] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try { setInc(await call('securelink_incident', { p_incident: id })); setError(''); }
    catch (e) { setError(e.message); }
  }, [id]);
  useEffect(() => { load(); const t = setInterval(load, 10_000); return () => clearInterval(t); }, [load]);
  useEffect(() => (me?.agency?.id ? listen(`sl:agency:${me.agency.id}`, ['position', 'audio', 'incident', 'signal_lost'], (_e, p) => { if (!p?.id || p.id === id) load(); }) : undefined), [me?.agency?.id, id, load]);

  const act = async (fn, args) => {
    setBusy(true);
    try { await call(fn, { p_incident: id, ...args }); await load(); }
    catch (e) { setError(e.message); }
    finally { setBusy(false); }
  };

  if (error && !inc) return <><Header back="/respond" /><main className="page"><div className="card"><p>{error}</p><button type="button" className="btn" onClick={() => navigate('/respond')}>Back</button></div></main></>;
  if (!inc) return <div className="center"><div className="spinner" /></div>;
  const cat = CATEGORIES[inc.category] || CATEGORIES.general;
  const open = ['active', 'acknowledged'].includes(inc.status);
  const last = inc.trail?.length ? inc.trail[inc.trail.length - 1] : (inc.lat != null ? { lat: inc.lat, lng: inc.lng } : null);

  return (
    <>
      <Header back="/respond" />
      <main className="page wide">
        <p className="kicker">{cat.long} · raised {ago(inc.startedAt)} · {inc.status}</p>
        <h1 className="h">{inc.person?.name}</h1>
        <div className="row wrap">
          {inc.person?.phone ? <a className="btn primary" href={`tel:${inc.person.phone}`}>Call {inc.person.phone}</a> : <span className="muted small">No phone number on this account.</span>}
          {last ? <a className="btn" href={`https://www.google.com/maps/dir/?api=1&destination=${last.lat},${last.lng}`} target="_blank" rel="noopener noreferrer">Directions</a> : null}
        </div>
        {inc.signalLost ? <p className="err">Signal lost: the phone last reported {ago(inc.lastSeenAt)}. Go to the last known position.</p> : null}
        {inc.note ? <p className="note">“{inc.note}”</p> : null}

        {last ? <TrailMap trail={inc.trail?.length ? inc.trail : [last]} accuracy={inc.accuracy} /> : <div className="card empty">No location yet. The person may have location switched off.</div>}

        {inc.audio?.length ? <section><h2 className="sub">Audio from the scene</h2>{inc.audio.map((a) => <Clip key={a.path} a={a} />)}</section> : null}

        {open && inc.status === 'active' ? <button type="button" className="btn primary big" disabled={busy} onClick={() => act('securelink_acknowledge')}>Take this alert</button> : null}
        {open && inc.status === 'acknowledged' ? (
          <form className="card" onSubmit={(e) => { e.preventDefault(); act('securelink_resolve', { p_outcome: outcome }); }}>
            <label htmlFor="outcome">Close the alert: what happened?</label>
            <textarea id="outcome" rows={3} maxLength={500} value={outcome} onChange={(e) => setOutcome(e.target.value)} placeholder="e.g. Reached her at 14:20; she is safe, suspect fled" required />
            <button type="submit" className="btn primary" disabled={busy || outcome.trim().length < 3}>Resolve</button>
          </form>
        ) : null}
        {!open ? <div className="card"><b>Closed.</b> {inc.outcome}</div> : null}
        {error ? <p className="err">{error}</p> : null}

        <ol className="timeline">
          {inc.events.map((e, i) => <li key={i}><time>{new Date(e.at).toLocaleTimeString('en-NG', { hour: '2-digit', minute: '2-digit' })}</time>{e.kind.replace('_', ' ')}{e.agency ? ` · ${e.agency}` : ''}</li>)}
        </ol>
      </main>
    </>
  );
}

function TrailMap({ trail, accuracy }) {
  const el = useRef(null);
  const map = useRef(null);
  useEffect(() => {
    if (!el.current) return;
    if (!map.current) {
      map.current = L.map(el.current, { attributionControl: true, zoomControl: true });
      L.tileLayer('https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png', {
        maxZoom: 19, attribution: '© OpenStreetMap contributors © CARTO',
      }).addTo(map.current);
    }
    const m = map.current;
    m.eachLayer((l) => { if (!(l instanceof L.TileLayer)) m.removeLayer(l); });
    const pts = trail.map((p) => [p.lat, p.lng]);
    const last = pts[pts.length - 1];
    if (pts.length > 1) L.polyline(pts, { color: '#1F7BFF', weight: 4, opacity: 0.8 }).addTo(m);
    if (accuracy) L.circle(last, { radius: accuracy, color: '#FF3B4D', weight: 1, fillOpacity: 0.12 }).addTo(m);
    L.circleMarker(last, { radius: 9, color: '#fff', weight: 3, fillColor: '#FF3B4D', fillOpacity: 1 }).addTo(m);
    m.setView(last, m.getZoom() && m.getZoom() > 3 ? m.getZoom() : 16);
  }, [trail, accuracy]);
  useEffect(() => () => { map.current?.remove(); map.current = null; }, []);
  return <div ref={el} className="map" role="img" aria-label="Map of the person's location and movement" />;
}

function Clip({ a }) {
  const [url, setUrl] = useState('');
  useEffect(() => {
    sb.storage.from('securelink-audio').createSignedUrl(a.path, 600).then(({ data }) => setUrl(data?.signedUrl || ''));
  }, [a.path]);
  return <div className="clip"><small>{new Date(a.at).toLocaleTimeString('en-NG')} · {a.seconds ?? '?'} s</small>{url ? <audio controls preload="none" src={url} /> : <span className="muted small">Loading…</span>}</div>;
}
