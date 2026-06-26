# LLM intent Worker (`@handsoff/llm-intent-worker`)

Resolves HandsOff voice/CUA intent through server-owned LLM providers while keeping provider
credentials out of the desktop webview and app bundle.

## Route

`POST /v1/resolve-intent`

- Requires `Authorization: Bearer <HANDSOFF_APP_TOKEN>`.
- Body: `{ "model": "gpt-4o-mini", "messages": [...] }`.
- On success returns `200 { "choices": [...] }` from the structured completion.
- Provider order is OpenAI first, then Gemini. Auth/billing/quota failures retry the next configured provider.

## Secrets

| Secret | Purpose |
| --- | --- |
| `OPENAI_API_KEY` | Optional OpenAI key used server-side by the Worker. |
| `GEMINI_API_KEY` | Optional Gemini key used server-side by the Worker. |
| `GOOGLE_API_KEY` | Optional alias for `GEMINI_API_KEY`. |
| `HANDSOFF_APP_TOKEN` | Shared app-cohort credential the desktop app presents as a bearer token. |

At least one provider key (`OPENAI_API_KEY`, `GEMINI_API_KEY`, or `GOOGLE_API_KEY`) must be set.
Optional model overrides: `OPENAI_MODEL`, `GEMINI_MODEL`.

## Wire the desktop app

```bash
export HANDSOFF_INTENT_WORKER_URL="https://<worker-host>/v1/resolve-intent"
export HANDSOFF_INTENT_APP_AUTH_TOKEN="<the HANDSOFF_APP_TOKEN value>"
```

## Local checks

```bash
corepack pnpm --filter @handsoff/llm-intent-worker test
corepack pnpm --filter @handsoff/llm-intent-worker build
```
