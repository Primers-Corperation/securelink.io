import { useEffect, useRef, useState } from 'react';

/** Watches the device position. status: 'pending' | 'on' | 'denied' | 'unavailable'. */
export function usePosition(active = true) {
  const [fix, setFix] = useState(null);
  const [status, setStatus] = useState('pending');
  const watch = useRef(null);
  useEffect(() => {
    if (!active) return undefined;
    if (!('geolocation' in navigator)) { setStatus('unavailable'); return undefined; }
    watch.current = navigator.geolocation.watchPosition(
      (p) => { setStatus('on'); setFix({ lat: p.coords.latitude, lng: p.coords.longitude, accuracy: Math.round(p.coords.accuracy), at: Date.now() }); },
      (e) => setStatus(e.code === 1 ? 'denied' : 'unavailable'),
      { enableHighAccuracy: true, maximumAge: 10000, timeout: 20000 },
    );
    return () => navigator.geolocation.clearWatch(watch.current);
  }, [active]);
  return { fix, status };
}

/** One quick fix (used at the moment an alert is raised). Resolves null rather than waiting long. */
export function quickFix(ms = 6000) {
  return new Promise((resolve) => {
    if (!('geolocation' in navigator)) return resolve(null);
    const timer = setTimeout(() => resolve(null), ms);
    navigator.geolocation.getCurrentPosition(
      (p) => { clearTimeout(timer); resolve({ lat: p.coords.latitude, lng: p.coords.longitude, accuracy: Math.round(p.coords.accuracy) }); },
      () => { clearTimeout(timer); resolve(null); },
      { enableHighAccuracy: true, maximumAge: 15000, timeout: ms },
    );
  });
}
