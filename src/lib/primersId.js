// "Continue with Primers ID": PKCE (S256) + state for one round trip. Primers ID returns a one-time
// code to /auth/primers; the primers-handoff function checks it and returns a single-use sign-in that
// gives this browser its own session for the same Primers ID account. No password, no email.
import { sb, SUPABASE_URL } from './supabase';

const PRIMERS_ID = 'https://id.primersgroup.ng';
export const CLIENT_ID = 'securelink';
const KEY = 'securelink-primers-flow';
export const redirectUri = () => `${window.location.origin}/auth/primers`;

const b64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const random = (n) => b64url(crypto.getRandomValues(new Uint8Array(n)));

export async function startPrimersSignIn({ create = false, returnTo = '/' } = {}) {
  const verifier = random(32);
  const state = random(16);
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  // localStorage, so the round trip survives the email-confirmation tab when creating an account.
  localStorage.setItem(KEY, JSON.stringify({ verifier, state, returnTo, at: Date.now() }));
  const u = new URL('/connect', PRIMERS_ID);
  u.search = new URLSearchParams({
    client_id: CLIENT_ID, redirect_uri: redirectUri(),
    code_challenge: b64url(new Uint8Array(digest)), code_challenge_method: 'S256', state,
    ...(create ? { prompt: 'create' } : {}),
  }).toString();
  window.location.assign(u.href);
}

/** Finishes the round trip and signs this browser in. Returns where to go next. */
export async function finishPrimersSignIn() {
  const params = new URLSearchParams(window.location.search);
  window.history.replaceState(null, '', window.location.pathname); // keep the code out of history
  let saved = null;
  try { saved = JSON.parse(localStorage.getItem(KEY) || 'null'); } catch { /* ignore */ }
  localStorage.removeItem(KEY);
  if (params.get('error')) throw new Error('Sign-in was cancelled.');
  const code = params.get('code');
  if (!saved || !code || params.get('state') !== saved.state || Date.now() - saved.at > 30 * 60_000) {
    throw new Error('That sign-in expired. Please try again.');
  }
  const res = await fetch(`${SUPABASE_URL}/functions/v1/primers-handoff`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ client_id: CLIENT_ID, redirect_uri: redirectUri(), code, verifier: saved.verifier }),
    signal: AbortSignal.timeout(15000),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.token_hash) throw new Error(data.error || "Couldn't sign you in. Try again.");
  const { error } = await sb.auth.verifyOtp({ token_hash: data.token_hash, type: 'magiclink' });
  if (error) throw new Error('That sign-in expired. Please try again.');
  return /^\/(?!\/)/.test(saved.returnTo || '') ? saved.returnTo : '/';
}
