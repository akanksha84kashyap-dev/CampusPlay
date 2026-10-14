# CampusPlay

**Find Your Game. Book Your Ground. Play Together.**

CampusPlay is a responsive campus sports web app for finding facilities, reserving slots, organizing games, and meeting teammates. The browser offers a local demo experience immediately. Supabase Auth, PostgreSQL, and Netlify Functions power the live deployment when configured.

## What works

- Browse exactly three seeded locations: MS Ground (cricket, volleyball, basketball, kabaddi, kho-kho, badminton, football, hockey), TB Court (table tennis), and ID Ground (ludo, chess, carrom, UNO, music chair). Search and filter by sport/activity.
- Make local demo bookings with date, opening-hour, capacity, duration, and overlap checks. Each booking gets a reference and supports cancellation/history.
- Create campus events, join or leave them, and filter by sport/date. Demo data is stored in this browser.
- Filter rule-based teammate recommendations. The explanation and score are transparent; there is no machine-learning claim.
- Responsive dashboard, profile form, sign-in/signup modal, and facility admin overview.
- Live backend functions for facility list, availability, bookings, events, player matching, match requests, reports, and manager facility reads/updates. Server handlers verify the Supabase access token and check ownership/authorization.
- PostgreSQL range exclusion constraint makes overlapping confirmed bookings mutually exclusive under concurrent requests. A row lock and uniqueness rule protect event capacity and duplicate participation.

## Project layout

```text
outputs/
├── index.html, styles.css, app.js
├── netlify.toml, package.json, .env.example
├── netlify/functions/          # server-only Netlify handlers
├── supabase/migrations/        # schema, constraints, RLS, RPCs
├── supabase/seed.sql           # rerunnable facility/college/operating-hours seed
└── HACKATHON.md                # pitch, diagrams, demo script, judge Q&A
```

## Run the demo locally

1. Install Node.js 20 or newer.
2. Open a terminal in this folder and run `npm install`.
3. Run `npm run dev` and open the local URL printed by Netlify CLI.
4. Browse, book, create events, and use the filters. The demo state is local to this browser; it is not a shared database.

## Configure Supabase and Netlify

1. Create a Supabase project. In the SQL editor, run `supabase/migrations/001_schema.sql`, then `supabase/seed.sql`.
2. In Supabase Auth, enable email/password. Set the Site URL to your deployed Netlify URL and add both that URL and `http://localhost:8888/**` to the allowed redirect URLs.
3. Copy `.env.example` to `.env`. Fill in `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY`. Keep the service-role key only in Netlify/local server environment variables; never put it in browser code or commit `.env`.
4. To turn on browser sign-in, add this before `app.js` in `index.html`, replacing the public values:

   ```html
   <script>
     window.CAMPUSPLAY_CONFIG = {
       supabaseUrl: 'https://YOUR_PROJECT.supabase.co',
       supabaseAnonKey: 'YOUR_PUBLIC_ANON_KEY'
     };
   </script>
   ```

   The anon key is intended for the browser; RLS still applies. The service key must never appear there.
5. In Netlify, connect the GitHub repository and set the three environment variables under **Site configuration → Environment variables**. Deploy. Netlify uses `netlify.toml` to publish this directory and its functions.
6. Set the Supabase Auth Site URL and redirect allow-list to the final Netlify domain, for example `https://your-site.netlify.app` and `https://your-site.netlify.app/**`.
7. Keep the demo domain aligned with the allowed college email domains you decide to support. The signup UI checks common `.edu` patterns as a usability check; server-side enrollment policy should be tightened to the college-domain rows before public launch.

## Live API surface

All requests use JSON and a Supabase access token in `Authorization: Bearer <token>` unless marked public. Error responses have `{ "error": "..." }`.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/facilities` | Active facility catalog |
| GET | `/api/availability?facility_id=…&date=YYYY-MM-DD` | Hourly available slots |
| GET/POST | `/api/bookings` | Own booking history / create booking |
| POST | `/api/bookings/:id/cancel` | Cancel an owned confirmed booking |
| GET/POST | `/api/events` | Upcoming events / create event |
| GET/PATCH | `/api/profile` | Read or update the signed-in user's safe profile fields |
| POST | `/api/events/:id/join` | Join with capacity and duplicate checks |
| POST | `/api/events/:id/leave` | Leave an event |
| GET | `/api/players?sport=Football` | Rule-based suggestions; private email is omitted |
| GET/POST | `/api/match-requests` | View own requests / invite a player |
| POST | `/api/reports` | Submit a report |
| GET/PATCH | `/api/facility-management/:id` | Manager-authorized facility management |
| GET | `/api/reports` | Admin usage counts and reports |

Netlify maps `/api/*` to the corresponding function name. The server-role client is used only after the function validates the bearer token with Supabase Auth. Booking writes call a database function and rely on the exclusion constraint, not an application-level pre-check.

## Verification checklist

These are repeatable manual checks for a configured Supabase/Netlify environment. Do not treat the local demo as proof of backend concurrency or RLS.

1. **Signup/login:** create a user with a permitted college address; confirm the email; sign in and sign out. Try an invalid password and an unconfirmed address.
2. **Availability:** request an open date and a closed date; verify hours, confirmed reservations, and closures affect the returned slots.
3. **Simultaneous booking:** with two users, send overlapping `POST /api/bookings` calls for the same facility and time at the same moment. Exactly one should return `201`; the other should return `409`.
4. **Cancellation:** cancel the first user's booking; verify history marks it cancelled and a new user can reserve the released time.
5. **Full event:** create an event with two seats, join from two accounts, then check the third account receives a conflict/full response.
6. **Duplicate registration:** join once, repeat the same join, and verify the second response is a conflict.
7. **Unauthorized edits:** call facility PATCH without a token, then as a student, then as a manager assigned to another facility. Expect `401`, `403`, and `403`; the assigned manager may change only their facility.
8. **RLS:** use the anon key directly to try reading another student's email and changing `is_admin`. The email is not selected by the public player API, and the database role trigger rejects privilege changes.
9. **Matchmaking:** set sports, skill, availability, and team size on two test profiles; query by sport and verify scores/reasons sort by shared rules without exposing email.

For a local syntax pass, run `npm run check`. Deployment and live database behavior require your own Supabase and Netlify credentials.

## Important production follow-up

The build is a hackathon-ready foundation, not an audited production service. Before public use, enforce college-domain membership in the signup/profile trigger, add per-user/function rate limits, configure email delivery and abuse reporting, review privacy/retention terms, add monitoring/backups, and validate policies against the project's actual Supabase roles. Apply schema migrations only to a disposable project first.
