//
//  HybridActionDriver.swift
//  DirectorSidecar
//
//  #148 — the hybrid CuaLoopDriver that makes IN-PROCESS native AX the DEFAULT actuation/read path
//  and keeps the external `cua-driver` only as the fallback for AX-opaque surfaces. It decorates the
//  real driver (`CuaDriverService`) and is what the loop is constructed with, so every call the loop
//  dispatches first tries the Director's own Accessibility grant:
//
//    • call(click/type_text/set_value) → native AX (resolve a real element, mutate, verify/rollback);
//      AX-opaque (Electron like Slack, canvas/WebGL), an unresolved element, no trust, or a failed
//      verify → the driver. Native is default; driver is fallback.
//    • get_window_state / list_windows → read IN-PROCESS (the #148 core fix), driver only when the
//      native read is empty/untrusted. Mirrors the window-source discipline (NativeWindowSource first,
//      driver fallback) already used for point→window targeting (#150).
//    • everything else (list_tools, launch_app, screenshots, …) → straight passthrough to the driver.
//
//  The hybrid sits BEHIND the loop's existing gate: VoiceCuaLoop.runGoalAction runs every step through
//  StepDispatch.firstBlockedStep (→ ToolCallGate) BEFORE dispatchPlan reaches `call`, so a mutating
//  verb is already gated/approved by the time it arrives here. This decorator never bypasses or
//  weakens that approval.
//

import Foundation
import OSLog

/// AX-first, driver-fallback `CuaLoopDriver`. `Sendable`: it holds only the (Sendable) wrapped driver
/// and a pure native-window source; the AX work is stateless (capture-before/restore-after is local).
final class HybridActionDriver: CuaLoopDriver {
    private let driver: any CuaLoopDriver
    /// The in-process on-screen window list (CGWindowList). Injectable so the routing is testable with
    /// a fake; the default is the real `NativeWindowSource` (#150).
    private let nativeWindows: @Sendable () -> [CuaWindow]

    init(
        driver: any CuaLoopDriver,
        nativeWindows: @escaping @Sendable () -> [CuaWindow] = { NativeWindowSource.onScreenWindows() }
    ) {
        self.driver = driver
        self.nativeWindows = nativeWindows
    }

    /// Generic dispatch. A mutating verb is attempted natively first; anything else (and any native
    /// miss) goes to the driver.
    func call(tool: String, input: JSONValue) async -> CuaResult<JSONValue> {
        // TODO(Phase 4 / #148-security): the full ClosedActionSet / GroundedAction / taint +
        // re-derivation security machinery (re-derive the admissible set at ACTION time and reject a
        // stale/tainted action) plugs in HERE, around the native dispatch. The SLICE keeps the
        // existing ToolCallGate/RiskGate (applied upstream in VoiceCuaLoop before this is reached);
        // it does NOT yet re-derive or taint-check. Risk is derived locally, never trusted from the model.
        guard let request = NativeActionRequest.decode(tool: tool, input: input) else {
            return await driver.call(tool: tool, input: input)  // not a native verb → passthrough.
        }
        // AX-first: a verified native actuation is the result; a native miss / unverified mutation
        // (AX-opaque surface, no trust, index no longer resolves) falls back to the driver.
        if let outcome = NativeAXActuation.perform(request), outcome.verified {
            DirectorDiagnostics.cua.info("native-ax dispatch tool=\(tool, privacy: .public)")
            return .succeeded(.string(outcome.summary))
        }
        DirectorDiagnostics.cua.info("native-ax miss tool=\(tool, privacy: .public) → driver fallback")
        return await driver.call(tool: tool, input: input)
    }

    /// Read the focused window's AX state IN-PROCESS; fall back to the driver when the native read is
    /// untrusted / AX-opaque (no actionable elements).
    func getWindowState(pid: Int, windowId: Int) async -> CuaResult<CuaWindowState> {
        if let state = NativeAXActuation.windowState(pid: pid, windowId: windowId, windows: nativeWindows()) {
            return .succeeded(state)
        }
        return await driver.getWindowState(pid: pid, windowId: windowId)
    }

    /// Native on-screen window list first (#150); driver only when the native list is empty.
    func listWindows() async -> CuaResult<[CuaWindow]> {
        let native = nativeWindows()
        if !native.isEmpty { return .succeeded(native) }
        return await driver.listWindows()
    }

    /// The tool catalog is the driver's self-described surface — always passthrough.
    func listTools() async -> CuaResult<[DriverToolDefinition]> {
        await driver.listTools()
    }
}
