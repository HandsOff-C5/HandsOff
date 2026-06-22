# @handsoff/desktop-app

The HandsOff macOS desktop shell — a Tauri v2 app (Rust backend + React/Vite
frontend) that hosts the mission-control dashboard. Issue
[#15](https://github.com/HandsOff-C5/HandsOff/issues/15) scaffolds the runnable
shell; gesture, STT, CUA, intent, and session logic land in their own lanes.

## Prerequisites

- **Node ≥ 22** and **pnpm** (via Corepack) — see the repo root `AGENTS.md`.
- **Rust toolchain** (`rustc`, `cargo`) — install via [rustup](https://rustup.rs).
- **Xcode Command Line Tools** — `xcode-select --install`.

## Run the app (dev)

```bash
corepack pnpm install                     # first time / after dep changes
corepack pnpm --filter @handsoff/desktop-app tauri dev
```

This launches the native window titled **HandsOff** showing the dashboard. The
`tauri dev` step runs `vite` (port 1420) via `beforeDevCommand` and points the
WebView at it.

> Frontend only? `corepack pnpm --filter @handsoff/desktop-app dev` serves the
> UI at <http://localhost:1420> in a browser (no native window).

## Speech-to-text (on-device, no setup)

STT is **provisioned by HandsOff, not bring-your-own-key** (AD2). The **default
provider is macOS on-device recognition**, so end users who download the app
need **no API key, no network, and nothing to configure**. It targets **all
supported Macs**: the baseline is on-device `SFSpeechRecognizer` (macOS 15–26,
builds with the current SDK), with `SpeechAnalyzer` added as a macOS-26 fast-path
(tracked in #81, built with the macOS 26 SDK). Audio never leaves the device.
The OS prompts once for Speech Recognition + microphone permission, surfaced
through the readiness/permissions panels.

### AssemblyAI hosted provider (optional)

AssemblyAI realtime stays behind the same `SttStream` seam as a deferred,
optional provider and is **off by default**. In production it will be
provisioned by a Cloudflare Worker that holds the provider key server-side; the
app ships no provider credentials. For local/dev cohorts against the hosted
provider, `stt_mint_token` reads the token Worker endpoint and app-auth
credential from the **Rust process environment** (not a Vite var, and not
`local-config.json`):

```bash
export HANDSOFF_STT_TOKEN_WORKER_URL="https://<worker-host>/v1/realtime-token"
export HANDSOFF_STT_APP_AUTH_TOKEN="<launch-cohort app token>"
corepack pnpm --filter @handsoff/desktop-app tauri dev
```

Without both values, `stt_mint_token` returns a recoverable provider setup error
when Realtime is selected — expected when using the on-device default.

## Layout

- `src/` — React frontend (`main.tsx` → `App` → `screens/dashboard/Dashboard`).
  Placeholder panels live under `src/features/*` for downstream lanes to fill.
- `src-tauri/` — Rust crate, `tauri.conf.json`, capabilities, and placeholder
  icons.

## Tests & checks

- **Render test** (runs in CI): `corepack pnpm test` — the dashboard render test
  asserts the window mounts, is branded HandsOff, and shows every panel.
- **Rust**: `cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml`
  (also wired into the `pre-push` hook).

## Deferred (not in #15)

- macOS artifact build + upload in CI → issue
  [#54](https://github.com/HandsOff-C5/HandsOff/issues/54).
- Signing / notarization / entitlements / CSP hardening → `area:release` (#55).
- Real brand iconography and design system → `area:release` / design. The
  current icon set is a placeholder.
