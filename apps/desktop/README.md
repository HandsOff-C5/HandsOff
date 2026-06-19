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
