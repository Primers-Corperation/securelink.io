// Guards the deploy config: the SPA rewrite must not swallow static files, and the CSP must allow
// exactly the hosts the app talks to (Primers ID, Supabase, map tiles).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const cfg = JSON.parse(readFileSync(new URL('../vercel.json', import.meta.url)));
const headers = Object.fromEntries(cfg.headers.flatMap((h) => h.headers).map((h) => [h.key, h.value]));
const csp = headers['Content-Security-Policy'];

test('SPA rewrite sends app routes to index.html but leaves files alone', () => {
  const re = new RegExp('^/' + cfg.rewrites[0].source.slice(1) + '$');
  for (const p of ['/', '/alert/abc', '/respond', '/auth/primers', '/privacy']) assert.ok(re.test(p), p);
  for (const p of ['/assets/index-abc.js', '/manifest.webmanifest', '/robots.txt', '/icon-192.png']) assert.ok(!re.test(p), p);
});

test('CSP allows the services the app needs and nothing inline', () => {
  assert.ok(csp, 'CSP present');
  assert.match(csp, /connect-src[^;]*https:\/\/atgqjrmcvpctywklfigb\.supabase\.co/);
  assert.match(csp, /connect-src[^;]*wss:\/\/atgqjrmcvpctywklfigb\.supabase\.co/);
  assert.match(csp, /script-src[^;]*https:\/\/id\.primersgroup\.ng/);
  assert.doesNotMatch(csp, /script-src[^;]*'unsafe-inline'/);
  assert.match(csp, /frame-ancestors 'none'/);
});

test('security headers are set', () => {
  assert.match(headers['Strict-Transport-Security'] ?? '', /max-age=\d{8}/);
  assert.equal(headers['X-Content-Type-Options'], 'nosniff');
  assert.match(headers['Permissions-Policy'] ?? '', /geolocation=\(self\)/);
});
