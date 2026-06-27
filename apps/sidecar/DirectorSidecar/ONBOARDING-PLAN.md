# Flow to First Run — native onboarding implementation plan

Adapts `HandsOff-Knowledge/Claude-Design_Director/Flow 2 - First Run.dc.html`
to the DirectorSidecar super-native SwiftUI design system. One window, four
views, wired to the real permission + rail systems. Light + dark, WCAG AA, HIG.

## The four views (one window, `id: "onboarding"`, 580pt, content-sized)

1. **Welcome** — real app icon, "Welcome to Director", one-line value prop,
   `Get started`, version footer.
2. **Point & Speak primer** — the basic-interaction tutorial: a mini desktop
   stage (reticle on a target window + a listening waveform/transcript chip),
   then Point / Speak explainer rows. Back / Continue.
3. **Permissions** — "Allow All" (functional, drives the REAL requests) + per-row
   Allow for Screen Recording, Accessibility, Microphone, Camera, each showing
   LIVE granted status. A non-blocking Computer-use engine (CUA) health row.
   Continue gates on the grantable permissions.
4. **Ready** — success state, granted chips, the **rail edge picker**
   (Left / Right segmented, default **Right**), `Open Home`.

Titlebar carries 4 progress dots (gold = reached), mirroring the mock.

## Wiring (real systems, no mocks)

- **Permissions** → `PermissionsService` (already exists). Live status via the
  sync readers (`screenRecordingState/accessibilityState/microphoneState/
  cameraState`); requests via `requestScreenRecording()`, `promptAccessibility()`,
  `requestMediaPermissions()` (+ two new granular `requestMicrophoneAndSpeech()`
  / `requestCamera()` helpers). "Allow All" runs them in sequence. A `Settings`
  affordance deep-links via `openPrivacySettings(_:)` for the grants that need a
  System-Settings toggle.
- **CUA health** → real `services.cua.checkPermissions()` via an injected
  closure; shows driver + screen/accessibility state. Informational, not a hard
  gate (so a missing dev daemon can't trap the flow).
- **Rail edge** → `RailController.edge` becomes mutable + `setEdge(_:)` re-anchors
  the live panel. The picker persists the choice and applies it immediately.
- **Persistence** → `AppPreferences` (UserDefaults — the native parallel to the
  mock's `localStorage`): `onboardingCompleted` + `railEdge`. The engine
  `LocalConfig` is left untouched (no risky Codable migration).
- **Light/dark** → `ThemedRoot { … }` resolves `Theme` from the system
  appearance; every surface uses theme tokens. No in-window theme toggle needed —
  the window follows the system, correct in both modes.

## Show-every-relaunch (testing) + later disable

`OnboardingGate.alwaysShow = true` forces the window every launch for iteration.
Finishing still writes `onboardingCompleted = true`, so flipping the flag to
`false` later restores normal "first run only" behavior with zero other changes.
The launch-time auto permission prompt is gated off while onboarding is showing,
so the onboarding buttons own the permission UX (no double-prompt at launch).

## Files

New (`DirectorSidecar/Onboarding/`):
- `AppPreferences.swift` — UserDefaults prefs + `OnboardingGate.alwaysShow`.
- `OnboardingModel.swift` — `@Observable @MainActor` step/permission/cua/edge
  state + injected closures (cuaCheck, setRailEdge, openHome, close).
- `OnboardingView.swift` — the window content + 4 step views + components.

Edited:
- `Permissions/PermissionsService.swift` — granular mic+speech / camera requests.
- `Rail/RailPanel.swift` — mutable edge + `setEdge(_:)`.
- `DirectorSidecarApp.swift` — onboarding model + closures, Window scene, launch
  open + auto-permission gating, `SurfaceHost` initial edge + `setRailEdge`.

## Verification

Compile via `xcodebuild` (this environment). Live rendering + the permission
prompts are the human visual gate on the re-signed `.app` (per AGENTS.md).
