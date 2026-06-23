# Agent Guide — Hands-Off (code)

Instructions for coding agents (Cursor, Claude Code, Codex) working in this repo.

## Project context lives next door

The team's research, decisions, and findings are in the **`HandsOff-Knowledge`** repo,
checked out as a sibling folder: `../HandsOff-Knowledge`.

- Product plan (what we're building): [`FINAL_PLANNING.md`](./FINAL_PLANNING.md) in this repo.
- Architecture decisions (ADRs): `../HandsOff-Knowledge/FINAL_Product Planning.md` (§ Architecture decisions, AD1–AD5).
- Research / evaluated tech: `../HandsOff-Knowledge/research/`.

If you make a decision worth recording, add an ADR in `../HandsOff-Knowledge`.

## Repository shape

A pnpm + TypeScript workspace; the macOS shell is a Tauri app.

- `apps/desktop/` — Tauri shell: web frontend (`src/`) + Rust commands (`src-tauri/`).
- `packages/contracts/` — shared schema-only types. **The only package every other area may import.**
- `packages/{desktop,gesture,speech,intent,cua,actions,supervision}/` — area-owned lanes (one owner each, mapped to `area:*` labels).
- `packages/testkit/` — cross-package fakes for tests.

**Boundary rule:** an area package may depend on `contracts` (and `testkit` in dev) only — never on another area package. Cross-area contracts go through `packages/contracts`.

## Code conventions

- Keep this repo code-only; research and notes belong in `HandsOff-Knowledge`.
- Many small, focused files over few large ones. Prefer immutable data; handle errors explicitly.
- Match the conventions already in the file you're editing.
- Prefer small high-conviction comments over long cosmetic notes.
- Do not use mocks, placeholders, fallbacks.
- Always defer from backwards-compatibility. Do not keep dead code.

## Local checks (run before you push)

```bash
corepack pnpm install      # first time / after dependency changes
corepack pnpm format       # auto-format
corepack pnpm lint         # eslint
corepack pnpm typecheck    # tsc -b — compiles the project-reference graph
corepack pnpm test         # vitest
```

TypeScript is wired as a **project-reference graph** (root `tsconfig.json` → each
package). One `tsc -b` typechecks/builds everything in dependency order, so
packages need no per-package compile scripts. Each package extends the config for
its runtime: `tsconfig.node.json` (e.g. `cua`, `actions`, `supervision`),
`tsconfig.dom.json` (e.g. `gesture`, `speech`, `desktop`), or `tsconfig.base.json`
(neutral: `contracts`, `intent`). Set yours to match where the code runs.

`lefthook` runs format/lint/typecheck on pre-commit and test/build on pre-push as a fast guardrail. **CI is authoritative** — hooks can be skipped, CI cannot.

## Quality gate (`just check`)

One entry point for humans, CI, and agents (implements `../HandsOff-Knowledge/docs/agent-dev-baseline.md` §7, issue #78):

```bash
just check       # authoritative TS gate — mirrors CI; green on a clean checkout
just check-rust  # Rust/Tauri gate (rustfmt, clippy, tests) — opt-in
just check-full  # + opt-in analyzers (knip, cargo audit/deny, semgrep); see `just setup`
```

Pinned toolchain is committed: `.node-version`, `rust-toolchain.toml`, `knip.json`, `deny.toml`. The Rust gate is opt-in/advisory until pre-existing `cargo fmt` drift in the desktop crate is cleaned up (child task of #78). Install `just` with `brew install just`. Shared agent MCP servers live in `.mcp.json` (Claude Code), `.cursor/mcp.json` (Cursor), and `.codex/config.toml` (Codex).

## Testing macOS permissions & Realtime STT

`tauri dev` crashes when the app requests microphone/speech or Realtime STT (the dev binary lacks a bundle identity macOS TCC requires). Use `tauri dev` only for UI/logic work. To test microphone/speech permissions or the AssemblyAI Realtime path, build and launch the bundled `.app`:

```bash
corepack pnpm --filter @handsoff/desktop-app exec tauri build --debug --bundles app
open -n apps/desktop/src-tauri/target/debug/bundle/macos/HandsOff.app \
  --env "HANDSOFF_STT_TOKEN_WORKER_URL=https://<worker-host>/v1/realtime-token" \
  --env "HANDSOFF_STT_APP_AUTH_TOKEN=<launch-cohort app token>" \
  --env "HANDSOFF_INTENT_WORKER_URL=https://<worker-host>/v1/resolve-intent" \
  --env "HANDSOFF_INTENT_APP_AUTH_TOKEN=<launch-cohort app token>"
```

Worker deploy + a curl smoke test live in `workers/assemblyai-token/README.md`.
The LLM intent Worker is documented in `workers/llm-intent/README.md`.

Head tracking follows the same TCC rule: test Camera/head tracking from the bundled `.app`, not `tauri dev`; this path must not require Input Monitoring.

## Performance

**Context management:** Avoid last 20% of context window for large refactoring and multi-file features. Lower-sensitivity tasks (single edits, docs, simple fixes) tolerate higher utilization.

## CI/CD & GitHub workflow — follow this exactly

Canonical source: `../HandsOff-Knowledge/docs/github-cicd.md`. The load-bearing rules:

**Flow:** issue → focused branch → PR linked with a closing keyword → CI + human review → squash-merge / GitHub issue automation → demo verification → Demo Verified.

- **`main` is protected.** No direct pushes, no force pushes. Every change lands through a PR.
- **One branch per issue**, named `feat/<issue>-slug` or `fix/<issue>-slug` (e.g. `feat/15-tauri-shell`, `fix/41-cua-health`). Use `chore/`, `docs/`, `test/` for non-feature work.
- **Open a draft PR early** and link the issue with **`Closes #<n>`** so GitHub issue/project automation can progress it. "Merged" is not demo-complete; **"done" is Demo Verified** (merged, then the issue's demo proof run from the built app).
- **One PR = one purpose**, with acceptance criteria. Every PR must include:
  - the user-visible behavior it improves,
  - **test proof** (actual test/CI output — never "tests should pass"),
  - demo proof (screenshot / video / log) if it changes UX, input, CUA, or agent behavior,
  - if an agent wrote it: the prompt / session summary.
- **If you change behavior, include the test** (unit / integration / eval) for that behavior. Behavior change without a test is incomplete.
- **Squash-merge only; delete the branch** after merge.
- **Scope-creep firewall:** a change is allowed only if it supports the core loop — *select live context → speak intent → create scoped plan → approve → execute through CUA/agent → supervise result.* Do not add a new product surface, command class, target-app promise, or bypass a safety/approval gate without project-lead approval.
- **Never commit secrets.** Use GitHub Secrets / OIDC. The secret-scan check must stay green.

### Required PR checks (CI)

`format` · `lint` · `compile` (`tsc -b`) · `test` · `secret-scan`. All must pass before review. The macOS desktop artifact build lands with the Tauri shell (issue #15).

### Labels

Tag every PR/issue with its area (`area:desktop`, `area:gesture`, `area:stt`, `area:intent`, `area:cua`, `area:agent-supervision`, `area:release`, `area:test`) and any risk (`risk:demo-blocker`, `risk:permission`, `risk:scope-creep`).
