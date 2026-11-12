# SecureLink

Emergency alerts for Nigeria, by Primers. One tap sends an alert with live location to the nearest
police, fire, ambulance and road-safety responders. If nobody takes it within two minutes the search
widens and asks again (up to three times).

- Public app: https://securelink.primersgroup.ng (this repo)
- Operator portal: https://portal.securelink.primersgroup.ng (repo `securelink-portal`)
- Sign-in: Primers ID (client `securelink`, handoff flow)

## How it works

| Part | Where |
| --- | --- |
| Web app (Vite + React) | `src/` — citizen alert, responder queue, incident map |
| Database + API | Supabase project `atgqjrmcvpctywklfigb`, schema `securelink` (`backend/001_securelink.sql`) |
| Escalation + lost-signal check | `pg_cron` job `securelink-tick`, every 30 s |
| Live updates | Supabase Realtime private broadcast: `sl:agency:<id>`, `sl:user:<uid>`, `sl:area:<cell>`, `sl:ops` |
| Audio clips | private storage bucket `securelink-audio` |
| Retention | `backend/002_retention.sql` + edge function `backend/functions/securelink-retention` (daily) |

Tables in `securelink` have RLS on and no policies: every read and write goes through the
`public.securelink_*` functions, which check the caller's role (citizen, responder, agency_admin,
platform_admin). Operators can see a victim's details only through a time-limited break-glass grant,
and every such view is written to the audit log.

## Develop

```bash
npm install
npm run dev      # http://localhost:5173
npm test         # deploy-config checks
npm run build
```

No environment variables are needed: the Supabase URL and publishable key are public and live in
`src/lib/supabase.js`. Pushing to `main` deploys to Vercel (project `securelink-app`).

## Responders

1. In the portal, create an agency (kinds, base location, radius) and issue an invite code.
2. The responder signs in to the app with Primers ID, opens Settings → Join an agency, and enters the code.
3. Alerts in range appear in their Respond queue in real time.

## Privacy

See `/privacy` in the app. Alerts are kept 12 months, the audit log 2 years. Contact:
primerscorperation@gmail.com.
