# AssemblyAI token Worker (`@handsoff/assemblyai-token-worker`)

Mints short-lived, single-use AssemblyAI v3 streaming tokens for the HandsOff
**Realtime** STT provider (#82, AD2). The provider API key lives only in this
Worker as a secret — the desktop app ships no provider credentials.

## Route

`GET /v1/realtime-token[?expires_in_seconds=<1..600>]`

- Requires `Authorization: Bearer <HANDSOFF_APP_TOKEN>` (app-cohort credential,
  compared in constant time). Missing → `401 missing_app_credential`;
  wrong → `403 invalid_app_credential`.
- On success returns `200 { "token": "<assemblyai-token>", "expiresInSeconds": <n> }`.
- Any other path → `404`; non-GET → `405`; upstream failure → `502`.

## Secrets (set out-of-band, never committed)

| Secret | Purpose |
| --- | --- |
| `ASSEMBLYAI_API_KEY` | AssemblyAI account key used to mint upstream v3 tokens. |
| `HANDSOFF_APP_TOKEN` | Shared app-cohort credential the desktop app presents as a bearer token. |

`ASSEMBLYAI_TOKEN_ENDPOINT` is a plain (non-secret) var with a safe HTTPS default.

## Deploy (repeatable)

```bash
cd workers/assemblyai-token

# 1. Generate the app-cohort token (store it in your secret manager; the app
#    needs the same value as HANDSOFF_STT_APP_AUTH_TOKEN).
openssl rand -hex 32

# 2. Set the two Worker secrets (prompts for each value; never echoed into git).
wrangler secret put ASSEMBLYAI_API_KEY
wrangler secret put HANDSOFF_APP_TOKEN

# 3. Deploy.
corepack pnpm --filter @handsoff/assemblyai-token-worker deploy
```

`wrangler deploy` refuses to publish until both required secrets exist (enforced
by `secrets.required` in `wrangler.jsonc`). Deploy prints the public URL, e.g.
`https://handsoff-assemblyai-token.<subdomain>.workers.dev`.

## Wire the desktop app

Point the Rust host at the deployed Worker (see `apps/desktop/README.md`):

```bash
export HANDSOFF_STT_TOKEN_WORKER_URL="https://<worker-host>/v1/realtime-token"
export HANDSOFF_STT_APP_AUTH_TOKEN="<the HANDSOFF_APP_TOKEN value>"
```

## Verify a live deployment

```bash
URL="https://<worker-host>/v1/realtime-token"
TOKEN="<HANDSOFF_APP_TOKEN>"

curl -s -o /dev/null -w '%{http_code}\n' "$URL"                                  # 401
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer wrong" "$URL" # 403
curl -s -H "Authorization: Bearer $TOKEN" "$URL"                                 # 200 + token
```

## Local checks

```bash
corepack pnpm --filter @handsoff/assemblyai-token-worker test    # vitest
corepack pnpm --filter @handsoff/assemblyai-token-worker build   # wrangler deploy --dry-run
```
