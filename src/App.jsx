import { createContext, lazy, Suspense, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { Link, Navigate, Route, Routes, useNavigate } from 'react-router-dom';
import { sb } from './lib/supabase';
import { call, CATEGORIES } from './lib/api';
import { listen } from './lib/live';
import Welcome from './pages/Welcome';
import Home from './pages/Home';
import AlertPage from './pages/Alert';
import Respond from './pages/Respond';
import Settings from './pages/Settings';
import AuthReturn from './pages/AuthReturn';
import Privacy from './pages/Privacy';

// The map (Leaflet) is only needed by responders; keep it out of the SOS screen's first load.
const Incident = lazy(() => import('./pages/Incident'));

const Ctx = createContext(null);
export const useApp = () => useContext(Ctx);

export function Header({ back }) {
  const { me } = useApp();
  return (
    <header className="top">
      {back ? <Link to={back} className="back" aria-label="Back">‹</Link> : null}
      <Link to="/" className="brand"><img src="/securelink-logo.png" alt="" width="28" height="28" /> SecureLink</Link>
      <nav className="top-end">
        {me && ['responder', 'agency_admin'].includes(me.role) ? <Link to="/respond" className="chip-link">Responder</Link> : null}
        {me ? <Link to="/settings" className="chip-link" aria-label="Settings">Settings</Link> : null}
        <span id="primers-bar-slot" />
      </nav>
    </header>
  );
}

export default function App() {
  const [session, setSession] = useState(undefined);
  const [me, setMe] = useState(null);
  const [meError, setMeError] = useState('');
  const [nearby, setNearby] = useState(null);
  const navigate = useNavigate();

  useEffect(() => {
    sb.auth.getSession().then(({ data }) => setSession(data.session ?? null));
    const { data } = sb.auth.onAuthStateChange((_e, s) => setSession(s ?? null));
    return () => data.subscription.unsubscribe();
  }, []);

  const refreshMe = useCallback(async () => {
    if (!session) { setMe(null); return null; }
    try { const m = await call('securelink_me'); setMe(m); setMeError(''); return m; }
    catch (e) { setMeError(e.message); return null; }
  }, [session]);
  useEffect(() => { refreshMe(); }, [refreshMe]);

  // Signing out of Primers ID in the Primers bar signs out here too.
  useEffect(() => {
    const onAccount = (e) => { if (e.detail && e.detail.signedIn === false && session) sb.auth.signOut({ scope: 'local' }); };
    window.addEventListener('primers:account', onAccount);
    return () => window.removeEventListener('primers:account', onAccount);
  }, [session]);

  // Community alerts: if switched on, keep the coarse area fresh and listen for emergencies nearby.
  useEffect(() => {
    if (!me?.communityAlerts) return undefined;
    let stops = [];
    let stopped = false;
    const refreshArea = () => navigator.geolocation?.getCurrentPosition(async (p) => {
      try {
        const r = await call('securelink_set_area', { p_lat: p.coords.latitude, p_lng: p.coords.longitude });
        if (stopped) return;
        stops.forEach((s) => s()); stops = (r.neighbours || []).map((c) => listen(`sl:area:${c}`, ['nearby'], (_e, payload) => {
          setNearby({ ...payload, cat: CATEGORIES[payload.category] || CATEGORIES.general });
          navigator.vibrate?.(200);
        }));
      } catch { /* try again on the next refresh */ }
    }, () => {}, { maximumAge: 300000, timeout: 20000 });
    refreshArea();
    const t = setInterval(refreshArea, 10 * 60_000);
    return () => { stopped = true; clearInterval(t); stops.forEach((s) => s()); };
  }, [me?.communityAlerts]);

  const value = useMemo(() => ({ session, me, refreshMe, setMe }), [session, me, refreshMe]);

  if (session === undefined) return <div className="center"><div className="spinner" /></div>;

  return (
    <Ctx.Provider value={value}>
      {nearby ? (
        <div className="toast" role="alert">
          <b>{nearby.cat.long} reported near you</b>
          <span>Within about 5 km, just now. Stay alert and keep clear if it is safe to do so.</span>
          <button type="button" onClick={() => setNearby(null)}>OK</button>
        </div>
      ) : null}
      {session && meError && !me ? (
        <div className="center"><div className="card narrow"><p>{meError}</p>
          <button type="button" className="btn" onClick={refreshMe}>Try again</button>
          <button type="button" className="btn ghost" onClick={() => { sb.auth.signOut({ scope: 'local' }); navigate('/'); }}>Sign out</button></div></div>
      ) : (
        <Routes>
          <Route path="/" element={!session ? <Welcome /> : me ? <Home /> : <div className="center"><div className="spinner" /></div>} />
          <Route path="/alert/:id" element={session ? <AlertPage /> : <Navigate to="/" replace />} />
          <Route path="/respond" element={session ? <Respond /> : <Navigate to="/" replace />} />
          <Route path="/respond/:id" element={session ? <Suspense fallback={<div className="center"><div className="spinner" /></div>}><Incident /></Suspense> : <Navigate to="/" replace />} />
          <Route path="/settings" element={session ? <Settings /> : <Navigate to="/" replace />} />
          <Route path="/auth/primers" element={<AuthReturn />} />
          <Route path="/privacy" element={<Privacy />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      )}
    </Ctx.Provider>
  );
}
