import { useEffect, useRef, useState } from 'react';
import { Navigate, useNavigate } from 'react-router-dom';
import { Header, useApp } from '../App';
import { call, CATEGORIES } from '../lib/api';
import { quickFix, usePosition } from '../lib/location';

const COUNTDOWN = 3;

export default function Home() {
  const { me, refreshMe } = useApp();
  const navigate = useNavigate();
  const { fix, status } = usePosition(true);
  const [pending, setPending] = useState(null); // { category, trigger, left }
  const [error, setError] = useState('');
  const timer = useRef(null);

  const raise = async (category, trigger) => {
    setError('');
    try {
      const pos = fix && Date.now() - fix.at < 60_000 ? fix : await quickFix();
      const r = await call('securelink_raise', { p_category: category, p_trigger: trigger,
        p_lat: pos?.lat ?? null, p_lng: pos?.lng ?? null, p_accuracy: pos?.accuracy ?? null });
      await refreshMe();
      navigate(`/alert/${r.id}`);
    } catch (e) {
      setPending(null);
      setError(`${e.message} Call 112 if you are in danger.`);
    }
  };

  // A short countdown with a big Cancel stops pocket presses; then the alert goes.
  const start = (category, trigger = 'button') => {
    clearInterval(timer.current);
    setPending({ category, trigger, left: COUNTDOWN });
    navigator.vibrate?.(80);
    timer.current = setInterval(() => {
      setPending((p) => {
        if (!p) return p;
        if (p.left <= 1) { clearInterval(timer.current); raise(p.category, p.trigger); return { ...p, left: 0 }; }
        return { ...p, left: p.left - 1 };
      });
    }, 1000);
  };
  const stop = () => { clearInterval(timer.current); setPending(null); };
  useEffect(() => () => clearInterval(timer.current), []);

  // Optional shake trigger (Settings): three hard shakes within two seconds.
  useEffect(() => {
    let on = false;
    try { on = localStorage.getItem('securelink-shake') === 'on'; } catch { /* ignore */ }
    if (!on) return undefined;
    let hits = [];
    const onMotion = (e) => {
      const a = e.accelerationIncludingGravity; if (!a) return;
      const g = Math.sqrt((a.x || 0) ** 2 + (a.y || 0) ** 2 + (a.z || 0) ** 2);
      if (g < 25) return;
      const now = Date.now(); hits = hits.filter((t) => now - t < 2000); hits.push(now);
      if (hits.length >= 3) { hits = []; start('general', 'shake'); }
    };
    window.addEventListener('devicemotion', onMotion);
    return () => window.removeEventListener('devicemotion', onMotion);
  }, []);

  if (me?.activeIncident) return <Navigate to={`/alert/${me.activeIncident.id}`} replace />;

  return (
    <>
      <Header />
      <main className="page sos-page">
        <div className={`loc loc-${status}`} role="status">
          {status === 'on' && fix ? <>Location on · accurate to about {fix.accuracy} m</> :
           status === 'denied' ? <>Location is blocked. Responders won&apos;t know where you are. Allow location for this site in your browser settings.</> :
           status === 'unavailable' ? <>Can&apos;t get your location right now. Alerts still send; turn on location services if you can.</> :
           <>Finding your location…</>}
        </div>

        <button type="button" className="sos" onClick={() => start('general')} disabled={!!pending}>
          <span>SOS</span><small>Tap to alert every responder nearby</small>
        </button>

        <div className="cats">
          {['police', 'fire', 'accident', 'medical'].map((k) => (
            <button key={k} type="button" className={`cat cat-${k}`} onClick={() => start(k)} disabled={!!pending}>
              <b>{CATEGORIES[k].label}</b><small>{CATEGORIES[k].hint}</small>
            </button>
          ))}
        </div>

        {error ? <p className="err" role="alert">{error}</p> : null}
        <a className="call112" href="tel:112">Call 112 (free, any network)</a>
        {me?.role === 'citizen' ? null : <p className="fine center-text">Signed in as {me?.role === 'platform_admin' ? 'a SecureLink operator' : 'a responder'}.</p>}
      </main>

      {pending ? (
        <div className="overlay" role="alertdialog" aria-labelledby="cd-title">
          <div className="countdown">
            <p id="cd-title">{pending.left > 0 ? `Sending ${CATEGORIES[pending.category].long.toLowerCase()} alert in` : 'Sending…'}</p>
            <div className="count">{pending.left > 0 ? pending.left : ''}</div>
            {pending.left > 0 ? <button type="button" className="btn cancel big" onClick={stop}>Cancel</button> : <div className="spinner" />}
          </div>
        </div>
      ) : null}
    </>
  );
}
