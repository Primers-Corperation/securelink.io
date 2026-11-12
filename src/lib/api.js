import { sb } from './supabase';

const OFFLINE = 'No connection. Check your data or Wi-Fi.';

/** Calls a SecureLink database function; throws an Error with a message fit to show people. */
export async function call(fn, args = {}) {
  let res;
  try {
    res = await sb.rpc(fn, args);
  } catch {
    throw new Error(OFFLINE);
  }
  if (res.error) {
    const m = res.error.message || '';
    if (/Failed to fetch|NetworkError|timed out|aborted/i.test(m)) throw new Error(OFFLINE);
    if (/JWT|not authenticated|Sign in/i.test(m)) throw new Error('Your session ended. Sign in again.');
    throw new Error(m.length < 160 ? m : 'Something went wrong. Try again.');
  }
  return res.data;
}

export const CATEGORIES = {
  general: { label: 'SOS', long: 'Emergency', hint: 'Sent to every responder nearby', icon: '!' },
  police: { label: 'Police', long: 'Police emergency', hint: 'Attack, robbery, threat', icon: 'P' },
  fire: { label: 'Fire', long: 'Fire', hint: 'Fire, smoke, explosion', icon: 'F' },
  accident: { label: 'Accident', long: 'Road accident', hint: 'Crash, someone hurt on the road', icon: 'A' },
  medical: { label: 'Medical', long: 'Medical emergency', hint: 'Collapse, bleeding, labour', icon: '+' },
};

export function ago(iso) {
  if (!iso) return '';
  const s = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return new Date(iso).toLocaleDateString('en-NG', { day: 'numeric', month: 'short' });
}

export function since(iso) {
  const s = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 1000));
  const m = Math.floor(s / 60);
  return m ? `${m}:${String(s % 60).padStart(2, '0')}` : `${s}s`;
}
