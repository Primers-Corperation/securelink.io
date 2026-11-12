import { sb } from './supabase';

/** Listens on a private SecureLink channel. Returns a function that stops listening. */
export function listen(topic, events, onMessage) {
  const ch = sb.channel(topic, { config: { private: true } });
  for (const e of events) ch.on('broadcast', { event: e }, (msg) => onMessage(e, msg.payload));
  ch.subscribe();
  return () => { sb.removeChannel(ch); };
}

let audioCtx = null;
/** A short two-tone alert (needs one tap on the page first, as browsers require). */
export function chime() {
  try {
    audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
    const t = audioCtx.currentTime;
    [880, 660, 880].forEach((f, i) => {
      const o = audioCtx.createOscillator(); const g = audioCtx.createGain();
      o.frequency.value = f; o.type = 'square';
      g.gain.setValueAtTime(0.0001, t + i * 0.22); g.gain.exponentialRampToValueAtTime(0.25, t + i * 0.22 + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, t + i * 0.22 + 0.2);
      o.connect(g).connect(audioCtx.destination); o.start(t + i * 0.22); o.stop(t + i * 0.22 + 0.21);
    });
    navigator.vibrate?.([300, 120, 300, 120, 300]);
  } catch { /* sound is a nice-to-have */ }
}
