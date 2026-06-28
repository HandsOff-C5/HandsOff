# Email capture Worker (`@handsoff/email-capture-worker`)

Collects customer emails into **Supabase** and sends a **Loops** confirmation
email. Both provider keys live only in this Worker as secrets — the desktop app
ships no provider credentials, it presents the shared `HANDSOFF_APP_TOKEN`.

## Routes

### `POST /v1/subscribe`

- Requires `Authorization: Bearer <HANDSOFF_APP_TOKEN>` (constant-time compare).
  Missing → `401`; wrong → `403`.
- Body: `{ "email": "user@example.com", "source": "desktop" }` (`source` optional).
- Inserts the subscriber (case-insensitive unique), then triggers a Loops
  transactional email. The Worker sends only the recipient and a
  `confirmationUrl` data variable (`CONFIRM_BASE_URL?token=<uuid>`); Loops owns
  the subject / HTML / from in the dashboard template.
- `202 { "status": "confirmation_sent" }` on success.
  `200 { "status": "already_confirmed" }` if the email already confirmed.
  `400 invalid_email` / `invalid_json`; `502` on Supabase/Loops failure.

### `GET /v1/confirm?token=<uuid>`

- Flips `confirmed = true`. Idempotent. No auth (the unguessable token is the auth).
- `200 { "status": "confirmed" }` or `already_confirmed_or_unknown`.

## Setup

1. **Supabase:** run `migrations/0001_subscribers.sql` in the SQL editor.
2. **Loops:** create a transactional email in the Loops dashboard whose body
   references the `{{confirmationUrl}}` data variable. Its transactional id is
   committed as `vars.LOOPS_TRANSACTIONAL_ID` in `wrangler.jsonc` (non-secret).
3. **Secrets** (never commit — set out-of-band):
   ```bash
   cd workers/email-capture
   wrangler secret put SUPABASE_URL                 # https://<ref>.supabase.co
   wrangler secret put SUPABASE_SERVICE_ROLE_KEY    # service_role key (NOT anon)
   wrangler secret put LOOPS_API_KEY                # Loops API key
   wrangler secret put HANDSOFF_APP_TOKEN           # shared app-cohort token
   ```
4. **Deploy:** `pnpm deploy` (or `wrangler deploy`).

## Local test

```bash
wrangler dev
curl -X POST http://localhost:8787/v1/subscribe \
  -H "Authorization: Bearer <HANDSOFF_APP_TOKEN>" \
  -H "content-type: application/json" \
  -d '{"email":"you@example.com","source":"curl"}'
```

> **Security:** the desktop app must call this Worker, never Supabase/Loops
> directly. Ship only `HANDSOFF_APP_TOKEN` in the app, never the service-role or
> Loops keys. Supabase RLS is on with no public policies, so even a leaked anon
> key reads nothing.
