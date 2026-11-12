import { createClient } from '@supabase/supabase-js';

// SecureLink runs on the Primers ID account system. These are public values: the publishable key
// grants nothing by itself; every call is checked in the database against the signed-in person.
export const SUPABASE_URL = 'https://atgqjrmcvpctywklfigb.supabase.co';
const PUBLISHABLE_KEY = 'sb_publishable_Im6hG4bodTfH4PtQvyHp1g_PcOO_6-p';

export const sb = createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false, storageKey: 'securelink-auth' },
  global: { fetch: (input, init) => fetch(input, { ...init, signal: init?.signal ?? AbortSignal.timeout(15000) }) },
});

// Keep Realtime's token in step with the session so private channels stay authorised.
sb.auth.onAuthStateChange((_event, session) => {
  if (session?.access_token) sb.realtime.setAuth(session.access_token);
});
