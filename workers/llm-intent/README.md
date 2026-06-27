# LLM intent Worker (`@handsoff/llm-intent-worker`)

Resolves HandsOff voice/CUA intent through server-owned LLM providers while keeping provider
credentials out of the desktop webview and app bundle.

## Route

`POST /v1/resolve-intent`

- Requires `Authorization: Bearer <HANDSOFF_APP_TOKEN>`.
- Body: `{ "model": "gpt-4o", "messages": [...] }` (`model` is optional; omit it to use the default).
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

## Models

Defaults: `gpt-4o` (OpenAI) and `gemini-3.5-pro` (Gemini). The worker resolves the completion
against a strict structured-output schema (`nextToolCallSchema`) and the agent loop sends vision
input, so any configured model **MUST support OpenAI strict structured outputs and vision**.
`gpt-4o`/`gpt-4.1`-class and Gemini pro tiers are known-safe; o-series reasoning models need
structured-output verification before adoption.

Optional model overrides (authoritative over the defaults, applied without an app rebuild):
`OPENAI_MODEL`, `GEMINI_MODEL`. The request-body `model` is also honored; a `gemini-`prefixed
value routes to the Gemini base URL.

> Exact model ids are a known plan open-question — verify current ids before deploy and override
> via `OPENAI_MODEL` / `GEMINI_MODEL` if a newer strict-structured-output + vision tier is preferred.

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
