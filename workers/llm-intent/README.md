# LLM intent Worker (`@handsoff/llm-intent-worker`)

Resolves HandsOff voice/CUA intent through OpenAI while keeping provider
credentials out of the desktop webview and app bundle.

## Route

`POST /v1/resolve-intent`

- Requires `Authorization: Bearer <HANDSOFF_APP_TOKEN>`.
- Body: `{ "model": "gpt-4o-mini", "messages": [...] }`.
- On success returns `200 { "choices": [...] }` from the structured OpenAI
  completion.

## Secrets

| Secret | Purpose |
| --- | --- |
| `OPENAI_API_KEY` | OpenAI key used server-side by the Worker. |
| `HANDSOFF_APP_TOKEN` | Shared app-cohort credential the desktop app presents as a bearer token. |

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
