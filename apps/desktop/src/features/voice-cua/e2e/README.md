# Live e2e loop harness (voice-cua)

An **opt-in** end-to-end harness that exercises the autonomous CUA loop against
the **real** pieces — the `cua-driver` CLI, the Cloudflare intent Worker, real
OpenAI, and the real `useVoiceCuaController` loop — with only the human inputs
(transcript, head-pointing snapshot, capture trace) mocked.

It exists because the fake-driver unit tests
(`../useVoiceCuaController.test.tsx`) pass while the live app can still hit a
stale/incompatible worker, a display-vs-window binding bug, or a loop that
repeats failed actions. This harness uses the real surface to catch those.

## Files

- `nodeCliDriver.ts` — a `CuaDriver` that shells out to `cua-driver`
  (`call` / `list-tools` / `describe`), the Node mirror of
  `apps/desktop/src-tauri/src/commands/cua.rs`. Records every `driver.call`.
- `workerHttpResolver.ts` — a `NextToolCallResolver` that POSTs `{model,
  messages}` to `HANDSOFF_INTENT_WORKER_URL` with
  `Authorization: Bearer $HANDSOFF_INTENT_APP_AUTH_TOKEN` and returns the
  worker's `{choices}` — the Node mirror of the Rust `intent_resolve` command.
- `liveLoop.e2e.test.tsx` — renders the hook with the two real adapters, drives
  `handleFinalTranscript`, and prints the captured intent / session / audit /
  `driver.call` trace. Includes the Bug A and Bug B reproductions.

## How to run

Guarded by `E2E_LIVE=1` (otherwise `describe.skipIf` skips it, so CI and a
normal `pnpm test` never run it). It needs the live driver on `$PATH`, network
access, and the worker secrets — so source `apps/desktop/.env.local` first:

```bash
set -a; . apps/desktop/.env.local; set +a
E2E_LIVE=1 corepack pnpm exec vitest run \
  apps/desktop/src/features/voice-cua/e2e/liveLoop.e2e.test.tsx
```

Override the driver binary with `HANDSOFF_CUA_DRIVER_BIN` if it is not named
`cua-driver` on `$PATH`.

## Side-effect safety

The harness launches a disposable **TextEdit** scratch window and drives only
that — it never types into the user's real apps. The happy-path case uses a
read-only goal.

## The two bugs it reproduces

- **Bug A (loop repeats a failed action):** goal "Open the Timeless app" (no
  such app). Asserts the loop does not dispatch the same failing `(tool,args)`
  more than twice; prints the repeat counts so a runaway is visible.
- **Bug B (binds to a Display, not a window):** mirrors the real app building
  `pointableWindows` from the **display** layout (`toAttentionWindows(displays)`
  in `features/camera/display-surfaces.ts` — surfaces with `app:"Display"` and
  no `pid`/`windowId`). Points the hand at a real window while saying "here" and
  asserts the bound referent is that **window** (pid+windowId), not the display.
