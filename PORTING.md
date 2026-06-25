# Tauri -> Swift Porting Guide

You are translating one Rust/Typescript/Typescript/React file to Swift/SwiftUi/AppKit. Read this whole document before writing any code. The goal is capture the logic faithfully and it compiles.
 Keep it current as the port moves. Code is still the source of
truth; this file records the migration path and the implementation nuance agents keep
rediscovering.

# Rule
Before finishing a migration task, update **Migration Notes** when you learn something
future agents need: contract drift, a native API caveat, a test command, a deleted seam,
or a temporary bridge. Keep notes short and cite concrete files.

Use this format:

```md
### YYYY-MM-DD **<next_number>**- short topic
- Files: `path/to/file`, `path/to/test`
- Note: what changed or what future agents must preserve.
- Check: command or test that proved it.
```

If the note is a product/architecture decision, also record it in
`../HandsOff-Knowledge`; do not turn this file into the ADR store.

## Non-Negotiables

- Preserve behavior before deleting the old stack.
- Keep `cua-driver` as the execution provider for the first Swift release; port the
  adapter, not the driver.
- Do not trust model-supplied risk. Derive action risk locally.
- Mutating and destructive/external actions require approval unless a new ADR and evals
  deliberately change the policy.
- Every behavior change needs a real unit, integration, or e2e test. Agent-facing calls
  also need golden eval coverage.
- Do not accept smoke tests as the only proof.
- Use real command/database/driver outputs for test assertions, not inferred text.

## Current Ownership

| Behavior | Current code | Swift target |
| --- | --- | --- |
| Main app shell, dashboard, plan/session UI | `apps/desktop/src` | `apps/sidecar/DirectorSidecar` promoted into the main app |
| Native command boundary | `apps/desktop/src-tauri/src/main.rs`, `apps/desktop/src-tauri/src/commands/` | Swift app services |
| CUA adapter | `apps/desktop/src-tauri/src/commands/cua.rs`, `packages/cua/src/tauri-driver.ts` | Swift `Process` wrapper around `cua-driver` |
| Action contracts and risk | `packages/contracts/src`, `packages/actions/src` | Swift models plus local risk/dispatch code |
| LLM next-action loop | `packages/intent/src`, `apps/desktop/src/features/voice-cua/useVoiceCuaController.ts` | Swift loop service |
| LLM/STT provider boundary | `workers/`, Rust commands in `intent.rs` and `stt.rs` | Swift clients calling the same worker boundary |
| Head pointer | `apps/desktop/src-tauri/sidecars/head-track` | In-process Swift camera/head-pointer service |
| Gesture overlay | `apps/desktop/src-tauri/sidecars/gesture-overlay` | In-process AppKit overlay service |
| SpeechAnalyzer bridge | `apps/desktop/src-tauri/src/speechanalyzer_bridge.swift` | Swift speech module |
| Native sidecar shell | `apps/sidecar/DirectorSidecar` | Main product shell |

## Porting Order

1. **Contracts first.** Port driver tools, action steps, sessions, readiness, audit, and
   risk enums to Swift. Add JSON fixture tests against current TypeScript-shaped payloads.
2. **CUA adapter next.** Implement the Swift `cua-driver` adapter with typed decoding for
   permissions, apps, windows, screenshots, `listTools`, and generic `call`.
3. **Loop before polish.** Port observe -> resolve -> risk gate -> dispatch -> observe,
   including budgets, interrupt, approval, failed-action memory, audit, and sessions.
4. **Promote the shell.** Make `DirectorSidecar` the app host once the service contracts
   exist. UI can lag engine parity; engine behavior cannot lag UI claims.
5. **Fold native sidecars.** Move head tracking, gesture overlay, and SpeechAnalyzer into
   Swift services. Delete sidecar stdin/stdout protocols only after replacement tests pass.
6. **Retire Tauri/React/Rust.** Remove old commands and dashboard only when Swift passes
   parity checks and old code is only a harness.

## Tauri to Swift Translation Rules

Prefer Swift services over recreating Tauri patterns literally. Tauri is a webview app
framework; Swift is the app runtime.

| Tauri concept | Swift replacement | Rule |
| --- | --- | --- |
| `invoke("command")` | Direct Swift service call | Use this inside native Swift UI. Only add a `WKScriptMessageHandler` when a webview still needs to call native code. |
| Tauri command modules | App-local service objects or Swift modules | Keep one service per behavior boundary: CUA, readiness, permissions, speech, hotkey, overlay, head pointer. |
| Tauri events | `AsyncStream`, `NotificationCenter`, or `@Observable`/`ObservableObject` state | Use `AsyncStream` for event feeds, observable models for UI state, and `NotificationCenter` only for app-wide OS-style broadcasts. |
| Tauri plugins | Native framework APIs or small app-local wrappers | Do not create plugin abstractions. Wrap the native API directly unless there are multiple implementations now. |
| Tauri sidecars | In-process Swift services first; helper tool or XPC only when isolation is required | Head tracking and gesture overlay should move in-process. Keep helper/XPC for crash isolation, privileges, or lifecycle independence. |
| Tauri shell/process APIs | `Process` | Use for `cua-driver` and any temporary external helper. Decode stdout/stderr into typed results. |
| Tauri webview bridge | `WKScriptMessageHandler` | Temporary only for any React/TypeScript harness left during migration. Do not make it the new engine boundary. |

Default shape:

```swift
struct DirectorServices {
  let cua: CuaDriverService
  let readiness: ReadinessService
  let speech: SpeechService
  let hotkey: HotkeyService
  let overlay: OverlayService
  let headPointer: HeadPointerService
}
```

Use helper tools or XPC only when one of these is true:

- The code needs a different entitlement, sandbox, or lifecycle.
- A crash must not take down the app.
- The helper already exists and is being kept temporarily during the port.
- The API requires a separate process boundary.

If none apply, keep it in-process.

## Compatibility Requirements

### CUA

The Swift adapter must preserve the current driver shape:

- `checkPermissions`
- `listApps`
- `listWindows`
- `launchApp`
- `getWindowState`
- `screenshot`
- `click`
- `typeText`
- `setValue`
- `listTools`
- `call(tool,input)`

Prefer generic `call(tool,input)` for new CUA tools so Swift does not grow a new wrapper
for every driver command.

### Risk

Use the current risk vocabulary unless a new decision changes it everywhere:

- `read_only`
- `reversible`
- `mutating`
- `destructive_external`

Approval is required for `mutating` and `destructive_external`.

Known drift to fix: existing Swift sidecar code has used `.destructive` and allowed some
mutating commits. Do not copy that policy forward by accident.

### Bridge

If Swift temporarily talks to a TypeScript/Rust engine, the bridge must publish real
engine state:

- readiness
- sessions
- transcript
- referents
- intent
- run result
- cursor/gaze focus when available
- commands for listen, commit, stop, approve, reject, pause, open home, select session

Do not overbuild the bridge if the target task is moving the engine into Swift.

## Test Gate

Minimum useful checks during the port:

```bash
corepack pnpm test
corepack pnpm typecheck
corepack pnpm lint
python3 -m compileall . # only if Python helpers are added
```

For Swift work, add a Swift unit/integration test.

Agent-facing behavior also needs golden evals. Current examples live under:

- `packages/intent/src/evals/voice-cua-goldens.test.ts`
- `packages/intent/src/evals/head-intent-llm-goldens.test.ts`

## Migration Notes

### 2026-06-25 **1** - initial porting map
- Files: `PORTING.md`, `../HandsOff-Knowledge/decisions/0005-complete-swift-migration.md`
- Note: the safe migration is behavior-first. Swift sidecars are real, but Rust/Tauri
  still owns native command/process boundaries and TypeScript owns the CUA/LLM loop.
- Check: `python3 ../HandsOff-Knowledge/skills/knowledge-note/scripts/validate_note.py ../HandsOff-Knowledge/decisions/0005-complete-swift-migration.md`

### 2026-06-25 **2** - shell readiness and risk type drift
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecar/Theme/StateColors.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/HUD/HUDModel.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/HomeDashboard/HomeDashboardModel.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/Contracts/ContractJSONValue.swift`
- Note: Swift shell code must use the contract risk case `destructive_external`, not the stale `.destructive`; derive approval locally for `mutating` and `destructive_external`. Home load state also needs readiness in the state calculation, or blocked mic/speech permissions render as an empty dashboard. Xcode/Swift rejects two compiled files with the same basename, so the contract-scoped arbitrary JSON type lives in `ContractJSONValue.swift` even though its type remains `Contracts.JSONValue`.
- Check: `xcodebuild test -project apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj -scheme DirectorSidecar -destination 'platform=macOS' -only-testing:DirectorSidecarTests`

### 2026-06-25 **3** - gesture-overlay fold-in: multi-display coordinate-space type edge cases
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecar/Overlay/DisplayGeometry.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/Overlay/OverlayWindow.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/Overlay/ReticleOverlayView.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/Overlay/GazeBracketLayer.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecarTests/G5bDisplayGeometryTests.swift`, ported from `apps/desktop/src-tauri/sidecars/gesture-overlay/OverlayGeometry.swift`
- Note: the gesture-overlay sidecar is now an in-process AppKit overlay SERVICE (one passthrough window per display); only its STDIN/STDOUT line protocol and `--selftest` stay in the sidecar for Rust to delete later. Edge cases on types that bit during the port:
  - **Three coordinate spaces, never conflate them.** (1) *Contract space* = virtual-desktop px, top-left origin, **y-DOWN** — what `cursorPosition`/`gazeFocus` publish and what `DisplayRect`/`OverlayLocation` use. (2) *Cocoa/AppKit* = bottom-left, **y-UP** (`NSScreen.frame`, `NSEvent.mouseLocation`). (3) *SwiftUI view* = top-left, y-down, LOCAL to each window. `DisplayGeometry` stays entirely in contract space (CoreGraphics `CGDisplayBounds` is already top-left/y-down — NO flip there); the y-flip is only `ScreenGeometry`/`resolvedViewPoint` turning contract→Cocoa around the PRIMARY height.
  - **`CGDirectDisplayID` is `UInt32`; widen to `Int` at the boundary.** `DisplayRect.id: Int` is the join key. `NSScreen` only exposes it via the untyped `deviceDescription[NSScreenNumber] as? NSNumber` → `Int($0.uint32Value)`. Must match the `Int(CGMainDisplayID())` produced by `DisplayGeometry.activeDisplays()`, or windows won't pair to their `DisplayRect`.
  - **"Primary" ≠ `NSScreen.main`.** Contract origin (0,0) is the menu-bar screen = `NSScreen.screens.first` (index 0). `NSScreen.main` is the KEY-window screen and moves with focus — using it for the y-flip height drifts the overlay when focus changes. The per-window y-flip height is the primary's, shared across all windows (not each display's own height).
  - **Half-open containment is load-bearing for the type's identity.** `DisplayRect.contains` uses `gx < x+width` (not `<=`), so a point on a shared seam belongs to exactly ONE display — otherwise a boundary cursor renders twice. Gap points (dead space between monitors) are NOT dropped: `locate` falls back to the nearest display, clamped to its bounds.
  - **`locate` returns `Optional` only for the empty-display case.** Callers must treat `nil` as "no displays" (degenerate), not "off-screen". A view passing empty `displays`/`nil` `displayID` is the single-primary fallback (raw contract point, original G5 behavior) — kept so existing G5 tests and any primary-only path are untouched.
  - **Deferred (no event consumer yet):** the sidecar's calibration TARGET ring (`TARGET`/`UNTARGET` verbs) is NOT ported — nothing in the bridge publishes a calibration target into Swift. It belongs with the head-track fold-in that owns calibration; adding it now would be a dead, unfed surface. Overlay window LEVEL stays `.floating` (the existing G5 product decision: above apps, below the menu bar), NOT the sidecar's `.screenSaver` — divergence is intentional.
- Check: `xcodebuild test -project apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj -scheme DirectorSidecar -destination 'platform=macOS' -only-testing:DirectorSidecarTests` (10 new `G5bDisplayGeometryTests` cover half-open edges, gap clamp, negative offsets, empty-nil)
