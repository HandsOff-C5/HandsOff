//
//  ElectronAccessibility.swift
//  DirectorSidecar
//
//  #148 — the Electron/Chromium accessibility accommodation, wired into the in-process AX read path.
//  Chromium-based apps (Slack, VS Code, Cursor, Discord, Electron generally) lazily build their AX
//  tree and expose NOTHING to a client until accessibility is explicitly requested — which is exactly
//  the "AX-opaque surface" the hybrid would otherwise always punt to the cua-driver. Setting the
//  app element's `AXManualAccessibility` to true is the documented external trigger that makes
//  Chromium construct and expose its tree, so a Slack/Cursor window becomes natively readable and
//  clickable instead of forcing a driver fallback every time.
//
//  This is the half of the rebuild's "Electron dance" that applies to this slice's verb set
//  (click / type_text / set_value, none of which move a window). The dance's size→position→size
//  ordering — with `AXEnhancedUserInterface` turned OFF so an Electron window's frame set actually
//  lands — is a window-PLACEMENT concern; it has no call site until a native window-move verb exists,
//  so it is intentionally not added here as uninvoked dead code (it belongs with that later slice).
//
//  Best-effort + idempotent: a non-Electron app simply ignores the attribute, and re-requesting is
//  harmless. Live-only (real AX), so it is exercised by the on-device gate, not headless CI.
//

#if canImport(ApplicationServices)
import ApplicationServices

enum ElectronAccessibility {
    /// Request that the app at `pid` build and expose its accessibility tree (the Chromium/Electron
    /// trigger). Returns whether the request was accepted; a native app or a non-Chromium target
    /// simply returns false, which is fine — the read then proceeds (or falls back) unchanged.
    @discardableResult
    static func enable(forPid pid: Int) -> Bool {
        let app = AXUIElementCreateApplication(pid_t(pid))
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }
}
#endif
