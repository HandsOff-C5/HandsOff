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

### 2026-06-25 **4** - contracts-first port: action steps / driver tools / sessions / audit / risk
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecar/Contracts/*` (`Contracts.swift`, `DriverTool.swift`, `Surface.swift`, `Referent.swift`, `RiskLevel+Policy.swift`, `ActionStep.swift`, `ActionPlan.swift`, `ToolCallTarget.swift`, `Cua.swift`, `Transcript.swift`, `Clarification.swift`, `Intent.swift`, `Session.swift`, `Audit.swift`), `apps/sidecar/DirectorSidecar/DirectorSidecarTests/ContractsDecodeTests.swift`, ported from `packages/contracts/src/*` + `packages/supervision/src/session-store.ts`.
- Note: the faithful full-shape contract ports (action-plan, driver-tools, audit, intent closure, session) now exist as `Contracts.*` and decode real TS-shaped JSON (13 fixture tests mirroring `audit.test.ts` + the action-plan/intent shapes). Type edge cases future agents keep needing:
  - **Namespace, don't collide.** The full ports live under `enum Contracts {}` so they coexist with the decode-only *lite* UI mirrors that already own the top-level names (`SurfaceSnapshot`, `SelectedReferent`, `SupervisionSession` in `Bridge/*`, plus `ResolvedIntentLite`/`ActionStepLite`). This is what let the contracts port and the parallel CUA-adapter port (top-level `CuaActionResult`/`CuaWindowState`/`JSONValue`) land in one target with ZERO type clashes. `RiskLevel` and `ExecutionStatus` are the deliberate exception — they stay top-level (the UI binds them) and `Contracts.*` references them as the single source of truth.
  - **Risk drift = enum + policy, split by owner.** The enum rename (`.destructive` → `.destructiveExternal = "destructive_external"`) is in `Theme/StateColors.swift` (UI-owned); the *policy* (`requiresApproval`, `rank`, `effective(of:)` = `riskLevelRequiresApproval` + `RISK_RANK` + the max-fold) is `RiskLevel+Policy.swift`. The UI's `risk.requiresApproval` call sites depend on that extension — it is the only definition, don't duplicate it.
  - **Discriminated unions → throwing `init(from:)` keyed on the tag.** `ActionStep`/`CuaActionRequest`/`CuaActionResult`/`ResolvedIntent`/`SupervisionAuditEvent` decode `kind`/`status` first, then the variant; an unknown tag THROWS (drift-loud, mirrors the zod discriminatedUnion). Do not model these as a struct-with-optionals.
  - **zod `.refine` invariants become throwing decodes.** `ActionPlan` rejects `requires_approval != riskLevel.requiresApproval`; `approval_decided` rejects `approval.actionId != actionId`; `satisfied` intent asserts `requires_approval=false`+`target_agent=none`. Keep these — they encode "derive the gate from risk, never trust the claim."
  - **`.nullable()` vs optional asymmetry.** TS `selectedReferentSchema.nullable()` is a REQUIRED key that may be `null` (audit `tool_call.referent`); Swift models it `decodeIfPresent` (absent OR null → nil), which is slightly more lenient (accepts a missing key). Real fixtures always send `referent: null`, so it round-trips; tighten to a presence check only if a producer omits the key.
  - **`z.record(z.unknown()).default({})` → `[String: Contracts.JSONValue]` defaulting to `[:]`.** `tool_call.args` is a self-describing passthrough (driver owns each tool's arg schema). Uses `Contracts.JSONValue` (the namespaced arbitrary-JSON enum in `ContractJSONValue.swift` — same-basename rule, see note 2), distinct from the CUA adapter's top-level `JSONValue`.
  - **`DriverTool` is 36, not the ADR prose's "38".** The live driver is the source of truth. Cases are camelCase with snake_case rawValues; an unknown name fails to decode (the model-hallucination boundary).
  - **`Contracts.Cua*` intentionally duplicates the adapter's top-level `Cua*`.** The audit/intent closure needs `cuaWindowStateSchema` with a PLAIN `SurfaceSnapshot`; the CUA adapter's `CuaWindowState` carries a `CuaWindow` (a SurfaceSnapshot superset with focus/bounds/zIndex). Not interchangeable — a future consolidation candidate, not a bug.
  - **Synthesized `Decodable` only honors an enum named exactly `CodingKeys`.** A mapping enum named `Key` with no custom `init(from:)` is SILENTLY IGNORED → the snake_case remap is lost → `keyNotFound("riskLevel")` on `risk_level` JSON. (This bit the golden harness's test-local projection structs; fixed.) Custom `init(from:)` referencing a `Key` enum is fine — that is how every `Contracts.*` union decodes.
- Check: `xcodebuild test -project apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj -scheme DirectorSidecar -destination 'platform=macOS' -only-testing:DirectorSidecarTests` (145 pass / 0 fail: 13 `ContractsDecodeTests` + the `GoldenEvalTests` that decode the real `packages/intent/src/evals` fixtures through `Contracts.*`)

### 2026-06-25 **5** - speech/STT service port: SpeechAnalyzer SDK gate and worker token shape
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecar/Speech/SpeechService.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecarTests/SpeechServiceTests.swift`, ported from `apps/desktop/src-tauri/src/commands/stt.rs`, `apps/desktop/src-tauri/src/commands/stt_ondevice.rs`, `apps/desktop/src-tauri/src/native_permissions.m`, `apps/desktop/src-tauri/src/speechanalyzer_bridge.swift`
- Note: Swift speech now has a native service boundary for hosted STT token minting and the on-device engine gate. Type edge cases to preserve:
  - **SpeechAnalyzer symbols must be SDK-gated, not only runtime-gated.** This checkout compiled with macOS 15.2 SDK, where `SpeechAnalyzer`/`SpeechTranscriber`/`AnalyzerInput` do not exist. Keep the actual SpeechAnalyzer session behind `#if HANDSOFF_HAS_SPEECHANALYZER`, matching the Rust build script's SDK probe; `@available(macOS 26.0, *)` alone is not enough because unavailable symbols still fail to compile.
  - **Engine choice is two inputs.** `selectedOnDeviceEngine(macOSMajorVersion:speechAnalyzerCompiled:)` mirrors `handsoff_stt_engine_for_macos_major`: runtime macOS >= 26 AND a compiled bridge select SpeechAnalyzer; otherwise fall back to SFSpeechRecognizer. Do not infer from runtime alone.
  - **Permission status integers overlap but are not identical.** `SFSpeechRecognizerAuthorizationStatus` is 0 notDetermined, 1 denied, 2 restricted, 3 authorized; `AVAuthorizationStatus` is 0 notDetermined, 1 restricted, 2 denied, 3 authorized. The speech service maps both 1 and 2 to contract `denied` for mic/speech start failures, matching the TypeScript on-device event mapper's practical UI behavior.
  - **Bundle permission metadata is part of the service port.** The Swift host must carry audio-input capability, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, and the explicit `com.apple.security.personal-information.speech-recognition` entitlement; otherwise the service code compiles but TCC cannot authorize the app for push-to-talk STT. The old Tauri bundle used `apps/desktop/src-tauri/entitlements.plist` + `Info.plist`; the Swift host now mirrors that with generated Info.plist keys plus `DirectorSidecar.entitlements`.
  - **Hosted provider secrets stay server-side.** `SpeechService.tokenRequest` takes only the Worker URL and app-cohort token, appends `expires_in_seconds`, and sends `Authorization: Bearer <app token>` to the Worker. It never knows the AssemblyAI API key and rejects non-HTTPS Worker URLs or URLs that already include query/fragment.
  - **Streaming service events are runtime STT types, not `Contracts.FinalTranscript`.** The intent contract still owns the stable final transcript shape under `Contracts.FinalTranscript`; the speech service owns partial/final/error/ready stream events and typed lifecycle errors.
- Check: `xcodebuild test -project apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj -scheme DirectorSidecar -destination 'platform=macOS' -only-testing:DirectorSidecarTests/SpeechServiceTests`

### 2026-06-25 **6** - golden evals as pre-resolver contract tests (complements note 4)
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecarTests/GoldenEvalTests.swift`, `packages/intent/src/evals/failed-action-recovery-goldens.json`, consuming `packages/intent/src/evals/{voice-cua,head-intent-llm}-goldens.json`
- Note: the four golden sets (voice intent, approval gates, pointing evidence, failed-action recovery) ship NOW as contract-decode tests — the resolver/loop aren't ported (Porting Order 3-4), so each fixture asserts only what's locally derivable and becomes a full end-to-end eval once the loop lands. The `CodingKeys`-naming and approval-`.refine` edge cases are in note 4; the golden-eval-specific ones:
  - **Single source of truth via `#filePath`, not copied JSON.** `GoldenSet.evalsDir` trims the known suffix `/apps/sidecar/DirectorSidecar/DirectorSidecarTests/` off `#filePath` to reach repo root, then reads `packages/intent/src/evals/*.json` — the SAME files the TS vitest goldens consume. No duplicated fixtures, so a TS-side golden edit can't silently drift from the Swift eval. Trade-off: the tests need the source tree on disk at run time (fine for local + CI-from-checkout; a fully detached bundle would not find them).
  - **Golden `status`/`intent_type` stay raw `String` — the resolved-intent vocabulary is not `ExecutionStatus`.** Goldens carry `status` ∈ {`ready`,`blocked`,`clarification_required`} and `intent_type` ∈ {`click`,`type_text`,`inspect`,…}; the top-level `ExecutionStatus` (SessionTypes.swift) is {`queued`,`running`,`succeeded`,`failed`,`blocked`,`rejected`} — overlap only on `blocked`. No intent-status enum is ported yet; do NOT decode golden `status` into `ExecutionStatus`.
  - **A failing decode IS the eval today.** For the head goldens the assertion that matters is that `Contracts.ActionPlan`/`ActionStep`/`SelectedReferent`/`SurfaceSnapshot` decode the real `completion` payload at all (kinds + typed-text projection, referent → plan-target surface). The `#expect`s on `actionKinds`/`actionTexts`/`referentId` are parity checks layered on top. The voice goldens have no `completion`, only the `expected` projection, so they assert the locally-derivable slice (approval gate from `risk_level`, `target_agent`/`reason` for non-ready).
  - **Reserved behavioral eval.** The failed-action golden pins the `CuaActionResult` discriminated-union shapes + the KD2 blocked-reason contract string ("kept retrying a call that already failed"); the *signature dedup* that PRODUCES the blocked tick needs `step-dispatch` (`driverCallForStep`/`callSignature`, not ported) + the loop. Fixture is shaped so the loop port later asserts "repeated failed (tool,args) → blocked" without touching the JSON.
- Check: `TMPDIR=$(mktemp -d) xcodebuild test -project apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj -scheme DirectorSidecar -destination 'platform=macOS' -only-testing:DirectorSidecarTests` → 146 pass (8 golden cases). NB: set a writable `TMPDIR` — the default can fail the xcresult write with `mkstemp: No such file or directory` and mask per-test results as failures.

### 2026-06-25 **6** - CUA adapter port: Process wrapper + driver/contract type edge cases
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecar/CUA/{JSONValue,CuaContracts,CuaDriverWire,CuaDriverService}.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecarTests/CuaAdapterTests.swift`, ported from `apps/desktop/src-tauri/src/commands/cua.rs` + `packages/cua/src/tauri-driver.ts`.
- Note: `CuaDriverService` is an `actor` wrapping `cua-driver` via `Process`. It owns the read/perception/catalog/generic surface (`checkPermissions`, `listApps`, `listWindows`, `getWindowState`, `screenshot`, `listTools`, `call`) and absorbs BOTH the Rust mapping AND the `tauri-driver.ts` client enrichment (there is no Tauri invoke seam natively). Type/contract edge cases future agents keep needing:
  - **The adapter's top-level `Cua*` are deliberately separate from `Contracts.Cua*` (note 3 confirms).** The adapter's `CuaWindowState`/`CuaScreenshot` carry the RICH `CuaWindow` (a SurfaceSnapshot superset with `focused`/`bounds`/`zIndex` — the live window the user acts on); `Contracts.CuaWindowState` carries a PLAIN `SurfaceSnapshot` for the audit record. Top-level `JSONValue` (JSONValue.swift) is the driver passthrough; `Contracts.JSONValue` (ContractJSONValue.swift) is `tool_call.args`. Not interchangeable — consolidation candidate, not a bug. `CuaWindow` REUSES the shared `Contracts.SurfaceAvailability`/`SurfaceAccessStatus` enums (one vocabulary) so it is a literal superset and exposes `var surface: Contracts.SurfaceSnapshot`.
  - **Adapter ABSORBS the `capturedAt` ISO-8601 stamp.** Rust `cua.rs` did NOT stamp window-state/screenshot; `tauri-driver.ts` added it client-side. The Swift adapter stamps it (`ISO8601DateFormatter` with `.withFractionalSeconds`) so its output is contract-valid `cuaWindowStateSchema`/`cuaScreenshotSchema`. Reads are wrapped in `CuaResult<T>` and thrown `CuaDriverError`s mapped to `.failed(error:)` — the loop never sees a Swift `throw` (mirrors the TS try/catch).
  - **Driver wire is snake_case; decode with `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`** (no per-field `CodingKeys`): `app_name`→`appName`, `window_id`→`windowId`, `z_index`→`zIndex`, `screen_recording`→`screenRecording`, `screenshot_png_b64`→`screenshotPngB64`. Output stays camelCase (NO strategy). Keep the two decoders separate.
  - **Tolerant `bounds`.** A window the driver can't measure → `bounds: nil` (Rust `#[serde(default)]`; Swift synthesizes `decodeIfPresent` for an optional, so a missing key auto-nils), NOT a whole-list parse failure.
  - **`focused` = max `zIndex` over the on-screen list** (HIGHER zIndex = frontmost). The binder resolves a head/hand point to the frontmost window under it.
  - **`elements` is ALWAYS `[]`; only `elementCount` is real** (Rust `map_elements` returns `vec![]` — ADR 0005 "element metadata" blocker). `CuaElement` exists for when the driver state exposes it; risk gating on semantic elements must verify through the generic `call` state.
  - **App `id` fallback = `bundleId ?? name.lowercased()`; `pid == 0` → `nil`** (installed-but-not-running). `pid`/`windowId` are modeled `Int` (Rust used `u32`; `Contracts.SurfaceSnapshot` uses `Int?`).
  - **Generic `call`: JSON passes through; a prose confirmation line degrades to `.string(...)`** (Rust `run_cua_value`) so an action tool that confirms in words never fails the passthrough. `input` is JSON-stringified for `cua-driver call <tool> <json>`.
  - **`screenshot` uses `get_window_state` `capture_mode:"vision"`** (inline base64 PNG); a missing `screenshot_*` field throws `CuaDriverError.missingField(<snake_case name>)` loudly. Typed mutating wrappers (`click`/`type_text`/`set_value`/`launch_app`) are NOT ported here — reachable via generic `call`, owned by the dispatch step (`Contracts.CuaActionRequest`).
  - **`Process` boundary: drain stdout AND stderr concurrently BEFORE `waitUntilExit()`** — a screenshot's base64 PNG can exceed the pipe buffer and `read-after-wait` deadlocks the child. Executable resolves via `/usr/bin/env` for PATH parity with Rust `Command::new("cua-driver")`; `.absolute(path)` override exists for a bundled binary. Spawn failure → `.failedToStart`, non-zero exit → `.nonZeroExit(stderr)`.
  - **No `project.pbxproj` edits needed.** The app + test folders are Xcode-16 `PBXFileSystemSynchronizedRootGroup`s (`objectVersion = 77`), so a `.swift` file dropped into `DirectorSidecar/CUA/` or `DirectorSidecarTests/` is auto-compiled. Tests use Swift Testing (`@Test`/`#expect`), not XCTest.
- Check: `xcodebuild test -project apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj -scheme DirectorSidecar -destination 'platform=macOS' -only-testing:DirectorSidecarTests` → `** TEST SUCCEEDED **`, 16/16 CUA cases (mappers/parsers/decode against real `cua-driver`-shaped JSON fixtures, no mocks).

### 2026-06-25 **6** - head-track fold-in: module→app symbol collisions, default-MainActor vs the camera queue
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecar/HeadTracking/*` (`HeadGeometry.swift`, `HeadPointerConfig.swift`, `HeadSignal.swift`, `FaceSelection.swift`, `HeadPointerMotion.swift`, `HeadTrackingModel.swift`, `VisionLandmarks.swift`, `HeadPointerEvent.swift`, `HeadPointerCursorOverlay.swift`, `HeadPointerService.swift`), `apps/sidecar/DirectorSidecar/DirectorSidecarTests/HeadTrackingTests.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj/project.pbxproj`, ported from `apps/desktop/src-tauri/sidecars/head-track/*`.
- Note: the `head-track` sidecar binary is now the in-process `HeadPointerService` (the `headPointer` slot in the DirectorServices shape) — front-camera AVCaptureSession + per-frame Vision face/landmark detection + the head-tracking model + the golden overlay. Type edge cases that bit during the port:
  - **Folding a standalone MODULE into the app module turns its top-level free funcs into module-global symbols.** The sidecar declared `clamp`/`center`/`distance`/`blend`/`area`/`clampIntoRealScreen`/`appKitToGlobalTopLeft`/… as bare free functions — fine in a one-file executable, but in the app module those generic names pollute (and risk colliding with) the global namespace, especially against the parallel overlay/gesture geometry work. Namespaced the generic math under `enum HeadGeometry` and the Vision helpers under `enum HeadLandmarks` (matching `ScreenGeometry`/`CuaWire`). Head-DOMAIN-named types/funcs (`HeadSignal`, `FaceCandidate`, `HeadPointerMotion`, `extractSignal`, …) stay top-level — collision-safe and keeps the port faithful. Verified zero collisions before porting; this is preventive + convention-matching.
  - **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` fights a background camera queue.** Every unannotated type/func becomes implicitly `@MainActor`, but `AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput` fires on the video queue and the model MUST mutate there. Swift 6.0 / Xcode 16.2 has **no `nonisolated class`** (only 6.1+; `nonisolated` on a class decl is a hard error here), so the service opts out per-member: every method is `nonisolated func`, and the self-synchronized mutable state (serialized on the session/video queues + an `NSLock`, exactly as the sidecar did) is `nonisolated(unsafe) var`. The class is `@unchecked Sendable`. The ONLY MainActor-isolated member is the overlay, reached via `MainActor.assumeIsolated { … }` inside a `DispatchQueue.main` block (which IS the main actor's executor) — that is also how NSScreen.screens is read.
  - **The pure value types are left implicitly `@MainActor` and it's benign — TODAY.** `HeadGeometry`/`HeadSignal`/`HeadPointerMotion`/`HeadTrackingModel`/etc. are nominally `@MainActor` (project default) yet are called from the nonisolated service on the video queue. Under the project's **Swift 5 language mode + minimal strict-concurrency** this produces ZERO diagnostics and no runtime actor hop (value-type methods run inline on the calling queue; thread-safety comes from the serial video queue). If the project later adopts Swift 6 language mode or strict concurrency, these become errors and each type needs explicit `nonisolated` members. Left as-is to keep the port faithful and the diff small.
  - **Two seams DELETED, not ported.** stdout JSON (`EventWriter`) → `events: AsyncStream<HeadPointerEvent>`; stdin control (`parseControlCommand`/`ControlCommand`) → typed `applyConfig(_:)` / `requestRecenter()`. The Rust host (`head_track.rs`: spawn, generation guard, stdout line buffering, auto-start-on-launch) dies with the process boundary — the host now calls `start()`/`stop()` directly. The deleted-seam self-test (`testControlCommandParsing`) is intentionally not ported.
  - **The Rust host's attention-window candidate ranking is NOT in this unit.** `head_track.rs` also ranked `cua_attention_windows()` against the latest head point on stop (`rank_attention_candidates`/`DEFAULT_RADIUS`). That is intent-CONSUMER logic, not sidecar code — it belongs with the loop/intent port and consumes the emitted `.point`. Out of scope here on purpose.
  - **The emitted point is already in contract space; the overlay point is not.** `HeadPoint.x/y` are flipped to CoreGraphics global top-left via `HeadGeometry.appKitToGlobalTopLeft` — the SAME primary-height flip as `ScreenGeometry.cocoaPoint` in reverse — so `.point` events drop straight onto the bridge `cursorPosition` topic with NO re-flip. The overlay (`HeadPointerCursorOverlay.show(at:)`) takes the PRE-flip AppKit point (bottom-left, y-up). Don't conflate the two: one event carries the contract point, the panel is positioned from the AppKit point.
  - **Optional `yaw`/`pitch` stay `Double?` end to end** (the wire emitted JSON `null`; no sentinel). **`confidence` is clamped to 0…1 at `HeadPoint` construction** (the wire clamped at encode time) — `HeadTrackingTests.headPointClampsConfidenceAndKeepsOptionalAngles` pins both.
  - **Camera permission in a SANDBOXED multi-platform app, no `.entitlements` file.** Used Xcode 16's resource-access setting `ENABLE_RESOURCE_ACCESS_CAMERA = YES` (auto-generates the `com.apple.security.device.camera` sandbox entitlement) + `INFOPLIST_KEY_NSCameraUsageDescription` in BOTH app-target configs — no manual entitlements file / `CODE_SIGN_ENTITLEMENTS` wiring. The sidecar's own `Info.plist`/`entitlements.plist` are now dead (its process is gone). The app imports AppKit unconditionally (de-facto macOS target) so the head-track AppKit code is NOT `#if os(macOS)`-guarded, matching the existing `OverlayWindow`/`ScreenGeometry` convention.
  - **The golden overlay stays self-contained** (`HeadPointerCursorOverlay`, renamed from the sidecar's `GoldenCursorOverlay`) — deliberately NOT wired into the parallel overlay rewrite (note 3). Its window level stays `.screenSaver` (the head pointer's own dot), distinct from the overlay service's `.floating`. Future consolidation candidate. Note 3's deferred calibration TARGET ring still has no Swift producer — head-track does not emit a calibration target here either, so that surface stays unfed until a calibration unit owns it.
- Check: `TMPDIR=$(mktemp -d) xcodebuild test -project apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj -scheme DirectorSidecar -destination 'platform=macOS' -only-testing:DirectorSidecarTests` → 8 `HeadTrackingTests` pass (face selection, signal+gate, motion response curve, periodic recenter, no-face recovery, top-left flip, gap clamp, typed-event invariants). NB writable `TMPDIR` per note 5.

### 2026-06-25 **7** - readiness window launch and stale bridge check
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecar/DirectorSidecarApp.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/ContentView.swift`
- Note: the Swift readiness view is exposed from the app menu as `Window > Engine Readiness`. It queries the loopback engine bridge at `127.0.0.1:51703`; before trusting the displayed state, run `lsof -nP -iTCP:51703 -sTCP:LISTEN` and confirm the listener is the intended current `handsoff` bundle, not an older worktree/debug build. For real bridge-stream checks, launch Director with `DIRECTOR_MOCK_FLEET=0`; Debug defaults can otherwise populate UI from `DevMockFleet` instead of the engine.
- Check: `xcodebuild -project apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj -scheme DirectorSidecar -configuration Debug -derivedDataPath /tmp/DirectorSidecarBuild build`, `open -n /tmp/DirectorSidecarBuild/Build/Products/Debug/Director.app --env DIRECTOR_MOCK_FLEET=0`, then open `Window > Engine Readiness`. Live bridge proof on 2026-06-25: raw stdlib WebSocket client got `HTTP/1.1 101 Switching Protocols` and a `state/readiness` frame; `lsof -nP -iTCP:51703 -sTCP:ESTABLISHED` showed `Director` connected to `handsoff`.

### 2026-06-25 **9** - Track C: LLM next-tool-call resolver + Worker client (provider boundary preserved)
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecar/Intent/{NextToolCall,NextToolCallPrompt,IntentWorkerClient,ResolvedIntentFactory}.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/Contracts/ToolRisk.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecarTests/NextToolCallResolverTests.swift`, ported from `packages/intent/src/llm/{next-tool-call,prompt}.ts` + `packages/contracts/src/tool-risk.ts` + the `workers/llm-intent` provider boundary.
- Note: `NextToolCallResolver.resolveNextToolCall` is the U3b autonomous-loop "head" — observe → resolve ONE next driver tool call → map onto `Contracts.ResolvedIntent`. The OpenAI SDK injection seam (`OpenAiIntentClient`) becomes the `NextToolCallClient` protocol; the live `IntentWorkerClient` POSTs `{model,messages}` to the CF Worker `/v1/resolve-intent` with the app-cohort Bearer token. Type/contract edge cases future agents keep needing:
  - **PROVIDER BOUNDARY UNCHANGED.** The app never holds `OPENAI_API_KEY`. `IntentWorkerClient` mirrors `SpeechService`'s token boundary (HTTPS-only, query/fragment-free, non-empty app token) and only ever sends the app token; the Worker holds the OpenAI key and runs the `nextToolCallSchema` structured-output completion. The Worker returns `{choices:[{finish_reason, message:{parsed, refusal}}]}` where `parsed` IS the `NextToolCall` — so the Swift client decodes the exact same shape the TS resolver consumed. `finish_reason` is snake_case on the wire (custom `CodingKeys`); the rest is camelCase. The transport is a `@Sendable (URLRequest) -> (Data, URLResponse)` seam (defaults to `URLSession`) so a test injects a canned Worker response with no network.
  - **Risk is DERIVED, never claimed (KD3).** `nextToolCallToIntent` validates the model's `tool` string against `Contracts.DriverTool` (hallucinated name → blocked) and derives the DISPLAY intent's provisional risk via `Contracts.ToolRisk.riskForToolName`, passing an EMPTY-BUT-PRESENT element target (`ToolCallTarget(element: .init(role:nil,…))`) so a `click` resolves to its reversible navigation base — NOT the no-element "gate everything" default. Mirrors the TS `{ element: {} }`. The loop (Track B dispatch) stays authoritative and re-escalates a proven commit click against the live snapshot. `requires_approval` is always `risk.requiresApproval`.
  - **`Contracts.ToolRisk` (tool-risk.ts) was the missing shared dependency — ported HERE, consumed by BOTH tracks.** Track B's `ActionDispatch/{StepDispatch,ToolCallGate}.swift` *call* `Contracts.ToolRisk.riskForToolCall`/`riskForToolName` but never defined them; this unit supplies the canonical per-tool classification (`base` TOOL_RISK map + `commitPatterns` word-ish regex + click/key/page refinements). It lives in `Contracts` (not `Intent`) for the same reason the TS module does — both the loop's reasoning side and the executor's gate side key risk off the tool name. `matchesCommitPattern` uses `(^|[^a-z])verb([^a-z]|$)` so "Send"/"Post reply" gate but "Resend"/"Description" don't.
  - **Decode-only contract types need construction seams — split by owner, no duplication.** `Contracts.ResolvedIntent.{Ready,Pending,Satisfied}` + `Contracts.ActionPlan` are Decodable-only. The `ActionPlan`/`Ready` memberwise inits are owned by Track B (`StepDispatch.swift`, note 8) and REUSED here; `ResolvedIntentFactory.swift` adds ONLY the `Pending`/`Satisfied` inits + the `blockedIntent` factory (fuse-intent.ts) Track B doesn't build. First attempt duplicated the `ActionPlan`/`Ready` inits → `invalid redeclaration`; deleted mine, kept theirs (shared-worktree coordination point).
  - **Two distinct `JSONValue`s bridged at the prompt.** `DriverToolDefinition.inputSchema` is the CUA-adapter top-level `JSONValue` (note 6); the prompt payload is assembled as the namespaced `Contracts.JSONValue` (note 4) and stringified (faithful to `JSON.stringify`), so `toolMenu` bridges one→the other case-for-case. The user payload emits explicit `null` where TS does `?? null` (pid/windowId/confidence/source/word), built via `Contracts.JSONValue` rather than synthesized Codable (which would OMIT nil keys). `JSONEncoder.withoutEscapingSlashes` matches `JSON.stringify`.
  - **Only the next-tool-call prompt is ported (Track C scope).** The legacy 6-kind `buildResolveIntentMessages`/`resolveWithOpenAi`/`openAiResolvedIntentSchema` are NOT — nothing native consumes the closed ActionStep path; the loop dispatches the generic `tool_call`. `candidateSurfacesFor` always passes `input.pointingEvidence` (the next-tool-call variant), so each candidate always carries `confidence`/`source` (null when unbound).
- Check: `TMPDIR=$(mktemp -d) xcodebuild test -project apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj -scheme DirectorSidecar -destination 'platform=macOS' -only-testing:DirectorSidecarTests` → `** TEST SUCCEEDED **`, 16 new `NextToolCallResolverTests` (act→ready tool_call, click navigation base, hallucinated-tool block, done/clarify/refusal/length/transport-error, args default/malformed→{}, prompt goal+snapshot+loop-memory+tool-menu, bound deictic referents + per-candidate confidence, ToolRisk bases+refinements+commit word-match, Worker client POST/HTTPS-guard/real-completion-decode/HTTP-error). All cases feed real TS-shaped JSON + a real `workers/llm-intent`-shaped completion through an injected `NextToolCallClient` — no network, no resolver mocks. (NB: full-target verification was momentarily blocked by an unrelated, uncommitted `Services/DirectorServices.swift` main-actor isolation error from a parallel track; the resolver + ToolRisk files compile clean and passed before it landed.)

### 2026-06-25 **10** - UI launch test stranded the machine in dark mode
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecarUITests/DirectorSidecarUITestsLaunchTests.swift`
- Note: `runsForEachTargetApplicationUIConfiguration` was `true` (Xcode template default), which runs `testLaunch()` once per UI configuration and switches the MACHINE's SYSTEM appearance (`AppleInterfaceStyle`) to Dark to render the dark configuration. An interrupted/incomplete `xcodebuild test` leaves the Mac in dark mode (observed live: `defaults read -g AppleInterfaceStyle` → `Dark` after a run; reverted with `osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false'`). We don't snapshot light/dark here, so set it to `false` — the launch test no longer touches system appearance and has nothing to leave dangling. Nothing in the app code sets appearance (repo-wide grep for `AppleInterfaceStyle`/`darkAqua`/System-Events-appearance is empty); this template flag was the sole cause.
- Check: `xcodebuild test … -only-testing:DirectorSidecarUITests/DirectorSidecarUITestsLaunchTests` runs `testLaunch()` ONCE (was twice = light+dark sweep) and `defaults read -g AppleInterfaceStyle` is unchanged across the run.

### 2026-06-25 **11** - Track F: wire ported services into the app lifecycle
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecar/Services/{DirectorServices,ServiceCoordinator}.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/DirectorSidecarApp.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecarTests/ServiceCoordinatorTests.swift`
- Note: the three ported engine services (`CuaDriverService`, `SpeechService.OnDeviceStream`, `HeadPointerService`) were compiled but instantiated NOWHERE — orphaned. Track F adds the `DirectorServices` container + a `@MainActor ServiceCoordinator` that binds their lifecycle to the app: `coordinator.start()` at `didFinishLaunching` (consume the head feed), `setSensing(on)` from `store.onListeningChanged` (camera + mic up/down with the "fn" listening toggle), `teardown()` at `willTerminate` (no leaked AVCaptureSession/AVAudioEngine). Type/lifecycle edge cases:
  - **A `@MainActor` default-argument expression does NOT inherit the type's isolation.** `DirectorServices.init(speech: = SpeechService.OnDeviceStream())` failed to compile (`call to main actor-isolated initializer in a synchronous nonisolated context`) even though the struct is `@MainActor` — default args evaluate in a nonisolated context. Fix: a no-arg `init()` that constructs the `@MainActor` `OnDeviceStream` inside the `@MainActor` init *body*, not as a default. Same trap will bite any `@MainActor` service handed a default-arg factory.
  - **`DirectorServices` holds only the THREE real ported services, not PORTING's aspirational `cua/readiness/speech/hotkey/overlay/headPointer` shape.** readiness = `cua.checkPermissions()` + the bridge; hotkey = `SurfaceHost.installFnHold`; overlay = the already-wired `OverlayController`/`OverlayModel`. Fabricating empty slots would be a dead surface (same "no unfed surface" rule the overlay/head-track folds followed).
  - **Head `.point` → `cursorPosition` is a pure projection (`HeadPointerBridge.pointer(from:)`), riding the SAME frame fan-out as the engine bridge.** The head point is already contract-space (top-left, y-down, flipped at emission via `HeadGeometry.appKitToGlobalTopLeft`), so x/y pass straight through; `kind:"user"`, no `agentId` → `Pointer.id == "user"` matches `OverlayModel.userId`, and `state:"moving"` makes the overlay treat it as a target (at-rest "stopped pointing" is the *absence* of points, which the overlay already hugs). This is the consumer `HeadPointerEvent.swift` said "a later consumer maps `.point` straight onto the bridge `cursorPosition` topic".
  - **Sensors run in non-mock mode ONLY.** `setSensing(on)` is called from `onListeningChanged` gated behind `!DevMockFleet.isEnabled` — the mock fleet owns the cursors in DEBUG, so the real camera/mic never start during dev demos (no permission prompts, no fighting the drawn mock cursors). Release builds always sense.
  - **Speech LIFECYCLE is Track F; the transcript CONSUMER is the loop (Track C/Porting Order 3).** `setSensing` brings the mic up/down and exposes events via `onSpeech`; the resolver attaches a consumer later without re-owning the AVAudioEngine lifecycle. Wiring it now means one owner of mic start/stop, not two.
  - **Testability seam: `HeadSensing`/`SpeechStreaming` protocols (retroactive conformance) so the coordinator injects fakes** — a front-camera AVCaptureSession + AVAudioEngine can't run under headless `xcodebuild`. Both protocols are `@MainActor`; `HeadPointerService`'s `nonisolated` members satisfy a `@MainActor` requirement (nonisolated is the more permissive side). The head-event consumer captures the `AsyncStream` (Sendable) on the main actor and hops back via `await self?.handle(_:)` so it never holds the actor across `await`. The LIVE sensor→cursor path still needs the bundled `.app` (per CLAUDE.md camera/mic can't run under `tauri dev`/headless) and is not proven by this suite.
- Check: `TMPDIR=$(mktemp -d) xcodebuild test -project apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj -scheme DirectorSidecar -destination 'platform=macOS' -only-testing:DirectorSidecarTests` → `** TEST SUCCEEDED **`, 250 pass / 0 fail incl. 6 `ServiceCoordinatorTests` (projection, sensing up/down idempotence, head-points-flow, non-point events skipped, teardown stops+finishes+inert, teardown-without-sensing). App target alone: `xcodebuild build … -scheme DirectorSidecar` → `** BUILD SUCCEEDED **`. NB writable `TMPDIR` (see note 6).

### 2026-06-25 **12** - Track E native app services: readiness / permissions / config / global fn hotkey
- Files: `apps/sidecar/DirectorSidecar/DirectorSidecar/Permissions/PermissionsService.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/Readiness/ReadinessService.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/Config/LocalConfigService.swift`, `apps/sidecar/DirectorSidecar/DirectorSidecar/Hotkey/FnHotkeyService.swift`, tests `DirectorSidecarTests/{PermissionsServiceTests,ReadinessServiceTests,LocalConfigServiceTests,FnHotkeyServiceTests}.swift`, ported from `apps/desktop/src-tauri/src/commands/{permissions,readiness,storage,hotkey}.rs` (+ contracts `packages/contracts/src/{readiness,config}.ts`).
- Note: four small, loop-independent app-services with their pure cores unit-tested. Type edge cases future agents keep needing:
  - **TWO permission-status mappers, because Apple's enums disagree on 1 and 2.** `SFSpeechRecognizerAuthorizationStatus` = 0 notDetermined, **1 denied, 2 restricted**, 3 authorized; `AVAuthorizationStatus` (camera+mic) = 0 notDetermined, **1 restricted, 2 denied**, 3 authorized. The 1/2 cases are SWAPPED, so `PermissionsService.speechState(fromRawStatus:)` and `.avState(fromRawStatus:)` stay separate (the readiness payload reports the distinct `restricted` vs `denied`). DISTINCT from `SpeechService.PermissionState` + `permissionState(nativeStatus:)` (note 5), which deliberately COLLAPSES `restricted`→`denied` for STT start-error UI — do not reuse it for readiness. The contract-faithful five-way `PermissionState` (granted/denied/not-determined/restricted/unknown) is a new top-level enum (mirrors `permissionStateSchema`); `accessibility`/`screen-recording` are boolean preflight reads, so they only ever yield granted/denied, never restricted/not-determined.
  - **Config default `speed` is 5 (contract), NOT 8 (head-track runtime).** `LocalConfig.default` is the contract `DEFAULT_LOCAL_CONFIG` (`{native, {edge, 5, 0.12}}`), spelled out rather than reusing `HeadPointerConfig.default` — whose `speed` is **8**, the value head-track raised for out-of-the-box feel (note 5/HeadPointerConfig.swift). The persisted config must round-trip the contract value. `LocalConfig` REUSES the head-track `HeadPointerConfig` (`Codable`, same camelCase) so the `headPointer` block decodes verbatim into what the head-pointer service consumes. A test pins both (`LocalConfig.default.headPointer.speed == 5` AND `HeadPointerConfig.default.speed == 8`) so the divergence can't silently collapse.
  - **`load` recovers-to-default; `update` rejects.** Faithful to `storage.rs`: `load` returns default AND rewrites it when the file is missing, undecodable (unknown `sttProvider`/`movementMode` → `Decodable` throws; old config missing `headPointer` → throws), or out-of-range (`speed∉[1,30]` or `distanceToEdge∉[0.02,0.4]` parses but fails `isValid`). `update` is stricter — it THROWS `.invalidSettings` on out-of-range instead of silently fixing. Missing-file detection matches BOTH `CocoaError.fileReadNoSuchFile` and the bridged `NSCocoaErrorDomain`/`NSFileReadNoSuchFileError`; any other read error throws. Path = `~/Library/Application Support/<bundleID>/local-config.json` (native equivalent of Tauri `app_config_dir().join(...)`); the file-URL functions are pure I/O so they unit-test in a temp dir exactly like the Rust tests. Writer appends a trailing `\n` to match `format!("{body}\n")`.
  - **Readiness is the NATIVE source of truth, producing the EXISTING bridge wire types.** `ReadinessService.payload(...)`/`.probe()` build the same `ReadinessPayload`/`CapabilityProbe` (BridgeTypes.swift) the loopback-bridge `getReadiness` path returns, so a consumer can swap `BridgeClient.requestReadiness()` → `ReadinessService.probe()` with zero downstream type change (that consumer swap is the NEXT step, not done here — `ContentView`/`BridgeClient` untouched to avoid colliding with the parallel bridge/UI work). The six capabilities and their ORDER mirror contract `CAPABILITY_IDS` + the Rust payload exactly; `cua` is the lone `daemon` and stays `unknown` (its probe lives in the CUA lane). `probe()` is read-only — never prompts.
  - **fn hotkey: deleted seams + the no-`nonisolated class` dance.** The Tauri `app.emit("hotkey://capture",{phase})` seam is DELETED → `FnHotkeyService.phases: AsyncStream<CapturePhase>` (one host consumer, like the single old webview listener); there is no webview. The pure `FnGesture` machine (Idle/Down/TapPending/SecondDown/Holding; `holdThresholdMs=250`, `multiTapWindowMs=300`) ports 1:1 and its 9 unit tests mirror `hotkey.rs` exactly. The CGEventTap layer uses the **Swift `CGEvent.tapCreate`** API (not raw FFI): listen-only on `CGEventMask(1<<CGEventType.flagsChanged.rawValue)`, reads `event.flags.contains(.maskSecondaryFn)`, and **re-enables on the `.tapDisabledByTimeout`/`.tapDisabledByUserInput` meta-events** (macOS auto-disables a slow tap). Same per-member concurrency opt-out as `HeadPointerService` (note 6): Xcode 16.2 has **no `nonisolated class`**, so the service is `@unchecked Sendable` with every worker-thread method `nonisolated` and the `FnGesture`/`tapPort` state `nonisolated(unsafe)` guarded by an `NSLock` on the dedicated CFRunLoop thread; the `@convention(c)` callback can't capture, so it round-trips `self` via `Unmanaged.passUnretained(...).toOpaque()` as `userInfo`. Consent: `AXIsProcessTrustedWithOptions` (Accessibility) + `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` (Input Monitoring) — both surfaced at `start()`, both needed before the tap installs, and macOS still swallows bare fn unless Keyboard > "Press fn (Globe) key to" = "Do Nothing". `start()` is idempotent.
  - **Actions use AppKit/CoreGraphics, not shell-outs.** `openPrivacySettings(_:)` opens the `x-apple.systempreferences:com.apple.preference.security?<anchor>` deep link via `NSWorkspace` (not `Command::new("open")`); the `PrivacyPane` rawValues + anchors match the old `open_privacy_settings` vocabulary. `requestScreenRecording()` = `CGRequestScreenCaptureAccess()` (REQUESTS + registers the app, vs the read-only `CGPreflightScreenCaptureAccess()` the probe uses). `requestMediaPermissions()` is `async` (speech via `SFSpeechRecognizer.requestAuthorization` continuation + `AVCaptureDevice.requestAccess` for audio/video), and drops the Rust payload's `"kind":"permissions"` webview discriminator.
  - **Not wired into the app here.** These are service files + tests (the Track E ask); instantiation/lifecycle belongs to the parallel Track F `DirectorServices`/`ServiceCoordinator` (note 11), which currently wires only `cua`/`speech`/`headPointer` and notes readiness/hotkey live elsewhere today. Wiring these readiness/hotkey/config consumers natively is the follow-up step, kept out of this unit to avoid colliding with the in-flight Track F/bridge work.
- Check: `TMPDIR=$(mktemp -d) xcodebuild test -project apps/sidecar/DirectorSidecar/DirectorSidecar.xcodeproj -scheme DirectorSidecar -destination 'platform=macOS' -only-testing:DirectorSidecarTests/PermissionsServiceTests -only-testing:DirectorSidecarTests/ReadinessServiceTests -only-testing:DirectorSidecarTests/LocalConfigServiceTests -only-testing:DirectorSidecarTests/FnHotkeyServiceTests` → `** TEST SUCCEEDED **` (29 cases: 7 permissions mappers/panes + 4 readiness payload + 9 config load/update/reset + 9 fn-gesture). NB writable `TMPDIR` per note 5.
