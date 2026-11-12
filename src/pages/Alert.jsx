import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { Header, useApp } from '../App';
import { sb } from '../lib/supabase';
import { call, CATEGORIES, since } from '../lib/api';
import { listen } from '../lib/live';
import { usePosition } from '../lib/location';

const CLIP_SECONDS = 30;

export default function AlertPage() {
  const { id } = useParams();
  const { session, refreshMe } = useApp();
  const navigate = useNavigate();
  const [inc, setInc] = useState(null);
  const [error, setError] = useState('');
  const [, tick] = useState(0);
  const open = inc && ['active', 'acknowledged'].includes(inc.status);
  const { fix, status: locStatus } = usePosition(!!open || !inc);
  const lastPing = useRef(0);

  const load = useCallback(async () => {
    try { setInc(await call('securelink_my_incident', { p_incident: id })); setError(''); }
    catch (e) { setError(e.message); }
  }, [id]);

  useEffect(() => { load(); const t = setInterval(load, 10_000); return () => clearInterval(t); }, [load]);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 1000); return () => clearInterval(t); }, []);
  useEffect(() => session ? listen(`sl:user:${session.user.id}`, ['incident'], () => load()) : undefined, [session, load]);

  // Live location while the alert is open, plus a heartbeat so a silent phone is noticed.
  useEffect(() => {
    if (!open || !fix || Date.now() - lastPing.current < 8000) return;
    lastPing.current = Date.now();
    call('securelink_ping', { p_incident: id, p_lat: fix.lat, p_lng: fix.lng, p_accuracy: fix.accuracy }).then(setInc).catch(() => {});
  }, [fix, open, id]);
  useEffect(() => {
    if (!open) return undefined;
    const t = setInterval(() => {
      if (Date.now() - lastPing.current < 20_000) return;
      lastPing.current = Date.now();
      call('securelink_ping', { p_incident: id }).then(setInc).catch(() => {});
    }, 5000);
    return () => clearInterval(t);
  }, [open, id]);

  // Keep the screen on while the alert is open.
  useEffect(() => {
    if (!open || !('wakeLock' in navigator)) return undefined;
    let lock = null;
    navigator.wakeLock.request('screen').then((l) => { lock = l; }).catch(() => {});
    return () => { lock?.release().catch(() => {}); };
  }, [open]);

  if (error && !inc) return <><Header back="/" /><main className="page"><div className="card"><p>{error}</p><button type="button" className="btn" onClick={load}>Try again</button></div></main></>;
  if (!inc) return <div className="center"><div className="spinner" /></div>;

  const cat = CATEGORIES[inc.category] || CATEGORIES.general;
  const closed = !open;

  return (
    <>
      <Header back={closed ? '/' : undefined} />
      <main className="page alert-page">
        <section className={`status status-${inc.unrouted && inc.status === 'active' ? 'unrouted' : inc.status}`} role="status" aria-live="polite">
          <p className="kicker">{cat.long} · {since(inc.startedAt)}</p>
          {inc.status === 'acknowledged' ? <><h1>{inc.agency} is responding</h1><p>A responder has taken your alert and can see your live location. Stay where it is safe.</p></> :
           inc.status === 'resolved' ? <><h1>Closed by {inc.agency || 'responders'}</h1><p>This alert has been resolved.</p></> :
           inc.status === 'cancelled' ? <><h1>You marked yourself safe</h1><p>Responders were told.</p></> :
           inc.unrouted ? <><h1>No responders cover this area yet</h1><p>{inc.blind ? 'We have not got your location. Allow location so we can find responders near you.' : 'SecureLink is still searching wider every two minutes.'} <b>Call 112 now.</b></p></> :
           <><h1>Alert sent to {inc.routedTo} {inc.routedTo === 1 ? 'responder agency' : 'responder agencies'}</h1>
             <p>Waiting for a responder to take it.{inc.escalations > 0 ? ` Searched wider ${inc.escalations} time${inc.escalations === 1 ? '' : 's'}.` : ' If nobody takes it in two minutes, it goes out wider.'}</p></>}
        </section>

        {open ? (
          <>
            <a className="call112 strong" href="tel:112">Call 112</a>
            <div className={`loc loc-${locStatus}`}>
              {locStatus === 'on' && fix ? <>Sharing live location · ±{fix.accuracy} m</> :
               locStatus === 'denied' ? <>Location is blocked. Allow it for this site so responders can find you.</> : <>Getting your location…</>}
            </div>
            <Recorder incidentId={id} />
            <SafeButton onSafe={async () => {
              try { setInc(await call('securelink_cancel', { p_incident: id })); await refreshMe(); }
              catch (e) { setError(e.message); }
            }} />
          </>
        ) : (
          <button type="button" className="btn primary" onClick={() => navigate('/')}>Done</button>
        )}

        {inc.events?.length ? (
          <ol className="timeline">
            {inc.events.map((e, i) => (
              <li key={i}><time>{new Date(e.at).toLocaleTimeString('en-NG', { hour: '2-digit', minute: '2-digit' })}</time>
                {{ raised: 'Alert raised', acknowledged: `${e.agency || 'A responder'} took the alert`, escalated: 'No answer yet: searched wider',
                   resolved: 'Resolved', cancelled: 'Marked safe', unrouted: 'No agency covers this spot' }[e.kind] || e.kind}</li>
            ))}
          </ol>
        ) : null}
        {error ? <p className="err">{error}</p> : null}
      </main>
    </>
  );
}

// Hold for two seconds, so it can't be pressed by accident.
function SafeButton({ onSafe }) {
  const [held, setHeld] = useState(0);
  const t = useRef(null);
  const down = () => { clearInterval(t.current); const s = Date.now();
    t.current = setInterval(() => { const p = Math.min(1, (Date.now() - s) / 2000); setHeld(p); if (p >= 1) { clearInterval(t.current); onSafe(); } }, 50); };
  const up = () => { clearInterval(t.current); setHeld(0); };
  return (
    <button type="button" className="safe" onPointerDown={down} onPointerUp={up} onPointerLeave={up} onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') down(); }} onKeyUp={up}
      style={{ '--held': held }}>
      <span>{held >= 1 ? 'Telling responders…' : "Hold: I'm safe now"}</span>
    </button>
  );
}

function Recorder({ incidentId }) {
  const [state, setState] = useState('idle'); // idle | recording | sending | sent | error
  const [msg, setMsg] = useState('');
  const rec = useRef(null);
  const record = async () => {
    setMsg('');
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') { setState('error'); setMsg('This browser cannot record audio.'); return; }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const type = ['audio/webm', 'audio/mp4', 'audio/ogg'].find((m) => MediaRecorder.isTypeSupported(m)) || '';
      const mr = new MediaRecorder(stream, type ? { mimeType: type } : undefined);
      const chunks = []; const started = Date.now();
      mr.ondataavailable = (e) => e.data.size && chunks.push(e.data);
      mr.onstop = async () => {
        stream.getTracks().forEach((tr) => tr.stop());
        setState('sending');
        try {
          const blob = new Blob(chunks, { type: mr.mimeType || 'audio/webm' });
          const ext = (mr.mimeType || 'audio/webm').includes('mp4') ? 'mp4' : (mr.mimeType || '').includes('ogg') ? 'ogg' : 'webm';
          const name = crypto.randomUUID().replace(/-/g, '');
          const path = `${incidentId}/${name}.${ext}`;
          const up = await sb.storage.from('securelink-audio').upload(path, blob, { contentType: blob.type, upsert: false });
          if (up.error) throw new Error('Upload failed');
          await call('securelink_add_audio', { p_incident: incidentId, p_path: path, p_seconds: Math.round((Date.now() - started) / 1000) });
          setState('sent'); setMsg('Sent to responders.');
        } catch { setState('error'); setMsg("Couldn't send the recording. Try again."); }
      };
      rec.current = mr; mr.start(); setState('recording');
      setTimeout(() => mr.state === 'recording' && mr.stop(), CLIP_SECONDS * 1000);
    } catch { setState('error'); setMsg('Microphone blocked. Allow it for this site to send audio.'); }
  };
  return (
    <div className="recorder">
      {state === 'recording'
        ? <button type="button" className="btn" onClick={() => rec.current?.stop()}>Stop and send recording</button>
        : <button type="button" className="btn" onClick={record} disabled={state === 'sending'}>{state === 'sending' ? 'Sending…' : `Record ${CLIP_SECONDS} s of audio for responders`}</button>}
      {msg ? <small>{msg}</small> : null}
    </div>
  );
}
