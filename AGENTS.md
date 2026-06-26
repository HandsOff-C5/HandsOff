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
- Never hardcode the product name `"HandsOff"` in TypeScript; import `APP_NAME` from `@handsoff/contracts` (the webview title is set from it in `apps/desktop/src/main.tsx`). `APP_NAME` can't reach non-TS layers, so a rebrand must also edit, under `apps/desktop/`: `src-tauri/tauri.conf.json` (`productName` + window `title`), `index.html` (`<title>`), `src-tauri/Info.plist` and the sidecar `Info.plist`s (permission prompts / bundle names), `src-tauri/src/commands/overlay.rs` (overlay window title), and `src-tauri/Cargo.toml`.
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

## Building & running the bundled app (mic/speech, STT, camera/head tracking, CUA)

`tauri dev` crashes when the app requests microphone/speech, Realtime STT, or Camera/head tracking — the dev binary lacks the bundle identity macOS TCC requires. Use `tauri dev` only for UI/logic work that touches none of those; for anything mic/speech/STT/camera/CUA, build and launch the bundled `.app`.

Worker URLs + app tokens live in `apps/desktop/.env.local` (gitignored). The Rust side reads each via `deployment_config(NAME, option_env!(NAME))` (`src-tauri/src/commands/mod.rs`): **runtime `std::env::var` first, then the value baked in at build time.** The clean path is to **source `.env.local` before the build** so the secrets bake into the binary via `option_env!` — the launched app then needs no environment (no secrets in argv or shell history):

```bash
# Source secrets so option_env! bakes them in at COMPILE time, then build.
set -a; . apps/desktop/.env.local; set +a
corepack pnpm --filter @handsoff/desktop-app exec tauri build --debug --bundles app
# Launch the self-contained bundle — no --env needed, secrets are baked in.
open -n apps/desktop/src-tauri/target/debug/bundle/macos/HandsOff.app
```

- **Source `.env.local` in the SAME shell as the build.** `option_env!` reads the env at compile time and shell state doesn't persist between commands; a build without it yields an app that returns `missing-configuration` / `missing-credentials` from the intent/STT commands. (Cargo doesn't track env-var changes, so if you change a secret, touch a file in the crate or `cargo clean` the affected unit to force a rebuild.)
- `--debug` builds far faster than release and is fine for manual testing; its bundle is under `target/debug/` (release lands in `target/release/`).
- **Runtime alternative** (skip a rebuild when a stale-but-built bundle exists): pass secrets at launch instead — `open -n <app> --env "HANDSOFF_INTENT_WORKER_URL=…" --env "HANDSOFF_INTENT_APP_AUTH_TOKEN=…" …` (macOS 13+; runtime env wins over the baked value). Prefer baking — `--env` puts secrets in the process list. Never paste secret values on a command line; always source the gitignored `.env.local`.

Worker deploy + a curl smoke test live in `workers/assemblyai-token/README.md`; the LLM intent Worker in `workers/llm-intent/README.md`. Head tracking follows the same TCC rule and must not require Input Monitoring.

## Building & running the Director sidecar (native Swift app)

`apps/sidecar/DirectorSidecar` is a **separate** native SwiftUI app (Xcode project, product `Director.app`) — not the Tauri bundle above. Its hands-off triggers need macOS privacy grants that ad-hoc signing keeps wiping on every rebuild, so the preferred loop is **build → re-sign with a stable identity → launch non-mock**:

```bash
PROJ=apps/sidecar/DirectorSidecar

# 1. Build (ad-hoc, the Xcode default).
xcodebuild -project "$PROJ/DirectorSidecar.xcodeproj" -scheme DirectorSidecar \
  -configuration Debug -destination 'platform=macOS' build
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/DirectorSidecar-*/Build/Products/Debug/Director.app | head -1)

# 2. Re-sign with your Apple Development cert so TCC grants survive rebuilds.
#    Find yours with: security find-identity -v -p codesigning
IDENTITY="Apple Development: junnaama@gmail.com (29PCUA5G33)"
codesign --force --deep --sign "$IDENTITY" \
  --entitlements "$PROJ/DirectorSidecar/DirectorSidecar.entitlements" "$APP"

# 3. Launch non-mock. Director reads its secrets from the environment at RUNTIME
#    (no option_env! baking like the Tauri app), so pass them via --env.
set -a; . apps/desktop/.env.local; set +a
open -n "$APP" \
  --env "HANDSOFF_INTENT_WORKER_URL=$HANDSOFF_INTENT_WORKER_URL" \
  --env "HANDSOFF_INTENT_APP_AUTH_TOKEN=$HANDSOFF_INTENT_APP_AUTH_TOKEN" \
  --env "HANDSOFF_STT_TOKEN_WORKER_URL=$HANDSOFF_STT_TOKEN_WORKER_URL" \
  --env "HANDSOFF_STT_APP_AUTH_TOKEN=$HANDSOFF_STT_APP_AUTH_TOKEN" \
  --env "DIRECTOR_MOCK_FLEET=0" \
  --env "PATH=$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
```

- **Why re-sign (step 2 is the important one).** An ad-hoc signature's designated requirement is the binary's cdhash, which changes on every build — so macOS TCC revokes Accessibility / Input Monitoring / Screen Recording each rebuild and the fn hotkey + CUA silently stop working. Signing with the Apple Development cert gives a **cert-based** designated requirement (`certificate leaf[subject.CN] = "Apple Development: …"`) that is identical across rebuilds: grant the permissions **once** and they persist. Verify with `codesign -d -r- "$APP"`.
- **Why not Xcode automatic signing.** No Apple ID is logged into Xcode for this team, so automatic provisioning fails (`No signing certificate "Mac Development" found`). The manual `codesign` re-sign sidesteps Xcode's provisioning entirely and uses the cert already in the keychain. (If you log your Apple ID into Xcode, automatic signing with `DEVELOPMENT_TEAM` set would also work and could replace step 2.)
- **Grants needed** (System Settings ▸ Privacy & Security, grant once after step 2): the global fn (Globe) hotkey needs **Accessibility** + **Input Monitoring**; CUA window perception needs **Screen Recording**. Also set Keyboard ▸ "Press fn (Globe) key to" → **Do Nothing** so macOS doesn't swallow the bare fn.
- **App Sandbox is off** (`ENABLE_APP_SANDBOX=NO` + the entitlement) on purpose: a sandboxed app cannot be a trusted Accessibility client, which the session-wide CGEventTap requires.
- **`DIRECTOR_MOCK_FLEET=0`** runs the real CUA fleet (omit or `=1` for the mock fleet); `~/.local/bin` must be on `PATH` so `cua-driver` resolves.
- **Always launch with `open -n`**, never `Contents/MacOS/Director` directly — direct exec bypasses LaunchServices, breaking the bundle/Info.plist + TCC identity association and crashing on signing/dylib checks. `--env` does put the token values in the process list (`ps`); that is inherent to Director's runtime-env model — never type the literal secrets, always expand them from the sourced `.env.local`.

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
