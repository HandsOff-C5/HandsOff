//
//  DevMockFleet.swift
//  DirectorSidecar
//
//  T-G1.8: a #if DEBUG canned publisher of `readiness` + `sessions` + `runResult` frames so the
//  menu is buildable/demoable before the engine `sessions` topic + OQ2 session list land
//  (data-plane deps #1/#2). Opt-in via the `DIRECTOR_MOCK_FLEET=1` launch env so it never fights
//  real engine data — when off, the app streams from the real bridge.
//

#if DEBUG
import Foundation

enum DevMockFleet {
    static var isEnabled: Bool {
        // Default ON in Debug so a plain ⌘R from Xcode shows the full demo with zero scheme setup.
        // Opt OUT (to connect to the real engine for live readiness) with DIRECTOR_MOCK_FLEET=0.
        ProcessInfo.processInfo.environment["DIRECTOR_MOCK_FLEET"] != "0"
    }

    /// When set, the HUD loop resolves a DESTRUCTIVE intent so the optional Greenlight footer
    /// renders and stays (awaitingGreenlight) — for eyeballing G2b.
    static var isDestructive: Bool {
        ProcessInfo.processInfo.environment["DIRECTOR_MOCK_DESTRUCTIVE"] == "1"
    }

    static let allCapsGranted = ReadinessPayload(capabilities: [
        CapabilityProbe(id: "camera", kind: "permission", state: "granted"),
        CapabilityProbe(id: "microphone", kind: "permission", state: "granted"),
        CapabilityProbe(id: "speech-recognition", kind: "permission", state: "granted"),
        CapabilityProbe(id: "cua", kind: "daemon", state: "running"),
        CapabilityProbe(id: "accessibility", kind: "permission", state: "granted"),
        CapabilityProbe(id: "screen-recording", kind: "permission", state: "granted"),
    ])

    static func fleet(now: Date) -> SessionsPayload {
        let iso = ISO8601DateFormatter()
        return SessionsPayload(sessions: [
            SupervisionSession(
                id: "session-1", status: .running,
                startedAt: iso.string(from: now.addingTimeInterval(-95)),
                updatedAt: iso.string(from: now), finishedAt: nil,
                title: "Refactor auth module", agentLabel: "Claude Code"
            ),
            SupervisionSession(
                id: "session-2", status: .running,
                startedAt: iso.string(from: now.addingTimeInterval(-42)),
                updatedAt: iso.string(from: now), finishedAt: nil,
                title: "Fix flaky CUA test", agentLabel: "Cursor"
            ),
        ], counts: nil)
    }

    /// A canned Intention Log for the selected agent so the "Agent Logs" view (H4) demos with real
    /// rows — an intent, two gated tool calls (read auto-run + a mutating one approved), and the
    /// finish — exercising the risk / approval / result chips.
    static func auditLog(now: Date) -> AuditLogPayload {
        let iso = ISO8601DateFormatter()
        func at(_ offset: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(offset)) }
        return AuditLogPayload(entries: [
            AuditLogEntry(
                id: "session-1#0", sessionId: "session-1", actionId: "intent-1", kind: .intentCreated,
                recordedAt: at(-90), summary: "Plan ready: Summarize GitHub issue 42",
                tool: nil, risk: nil, approval: nil, result: nil),
            AuditLogEntry(
                id: "session-1#1", sessionId: "session-1", actionId: "intent-1", kind: .toolCall,
                recordedAt: at(-86), summary: "Tool get_window_state [auto]: Captured GitHub — Issue 42",
                tool: "get_window_state", risk: .readOnly, approval: .auto, result: .succeeded),
            AuditLogEntry(
                id: "session-1#2", sessionId: "session-1", actionId: "intent-1", kind: .toolCall,
                recordedAt: at(-70), summary: "Tool type_text [approved]: Typed the summary into Notes",
                tool: "type_text", risk: .mutating, approval: .approved, result: .succeeded),
            AuditLogEntry(
                id: "session-1#3", sessionId: "session-1", actionId: "intent-1", kind: .executionFinished,
                recordedAt: at(-68), summary: "Finished: succeeded: Typed the summary into Notes",
                tool: nil, risk: nil, approval: nil, result: nil),
        ])
    }

    static func mockIntent(destructive: Bool) -> ResolvedIntentLite {
        if destructive {
            return ResolvedIntentLite(
                id: "intent-9", status: .ready, intentType: "delete", riskLevel: .destructiveExternal,
                requiresApproval: true, summary: "Delete everything in ~/Documents", reason: nil,
                steps: [ActionStepLite(id: "s1", label: "Empty the Documents folder", kind: "set_value", targetTitle: "Finder", proposed: "(removes 412 files)")]
            )
        }
        return ResolvedIntentLite(
            id: "intent-1", status: .ready, intentType: "summarize", riskLevel: .readOnly,
            requiresApproval: false, summary: "Summarize GitHub issue 42", reason: nil,
            steps: [
                ActionStepLite(id: "s1", label: "Read the issue thread", kind: "inspect_window_state", targetTitle: "GitHub — Issue 42", proposed: nil),
                ActionStepLite(id: "s2", label: "Type the summary into Notes", kind: "type_text", targetTitle: "Notes", proposed: "TL;DR: flaky CUA test, fix the await race."),
            ]
        )
    }

    /// Launch state: a connected engine, a running fleet, and a selected agent's plan — so the
    /// Home Dashboard + Inspector are populated and fully interactive. NO overlays come up here
    /// (those are toggle-driven), so the menu + dashboard are never obstructed.
    @MainActor
    static func populate(
        dispatch: @escaping (BridgeFrame) -> Void,
        setState: @escaping (ConnectionState) -> Void,
        select: @escaping (String) -> Void,
        now: Date
    ) async {
        setState(.connected)
        dispatch(.state(topic: "readiness", readiness: allCapsGranted))
        dispatch(.sessions(fleet(now: now)))
        select("session-1") // bind the Inspector to the running agent (G4b)
        dispatch(.intent(mockIntent(destructive: isDestructive)))
        dispatch(.audit(auditLog(now: now))) // H4: populate the Agent Logs view
    }

    /// Activation loop (fired when the user toggles Listening on): the eye-gaze brackets morph,
    /// the Listening HUD fills (transcript → referents → intent), and the agent cursors travel.
    /// Cancelled when the user toggles off. No runResult — the HUD stays up until dismissed.
    @MainActor
    static func activationLoop(dispatch: @escaping (BridgeFrame) -> Void, now: Date) async {
        // A cancellation-aware pause: returns false the moment the loop is cancelled (toggle off),
        // so the remaining frames don't keep firing after Stop Listening.
        func pause(_ seconds: Double) async -> Bool {
            (try? await Task.sleep(for: .seconds(seconds))) != nil && !Task.isCancelled
        }
        dispatch(.gaze(GazeFocus(bounds: GazeRegion(x: 380, y: 240, w: 120, h: 36), confidence: 0.92, sizeClass: "element", ts: 100)))
        guard await pause(1.4) else { return }
        dispatch(.gaze(GazeFocus(bounds: GazeRegion(x: 320, y: 300, w: 460, h: 220), confidence: 0.9, sizeClass: "block", ts: 200)))

        guard await pause(0.8) else { return }
        dispatch(.transcript(TranscriptEvent(kind: "partial", text: "summarize that issue", confidence: 0.9, latencyMs: 120, receivedAt: 0)))
        guard await pause(0.8) else { return }
        dispatch(.transcript(TranscriptEvent(kind: "final", text: "summarize that issue", confidence: 0.96, latencyMs: 140, receivedAt: 0)))
        dispatch(.referents(ReferentsPayload(
            surfaces: [SurfaceSnapshot(id: "win-1", title: "#42 Flaky CUA test", app: "GitHub", pid: nil, windowId: nil, availability: "available", accessStatus: "granted")],
            selected: SelectedReferent(id: "win-1", source: "point", confidence: 0.9)
        )))
        guard await pause(1) else { return }
        dispatch(.intent(mockIntent(destructive: isDestructive)))
        if isDestructive { return }

        guard await pause(1) else { return }
        dispatch(.cursor(pointers: [
            Pointer(x: 720, y: 360, space: "virtual-desktop-px", kind: "agent", agentId: "session-1", agentLabel: "Claude Code", state: "moving", confidence: 0.95, ts: 1000),
            Pointer(x: 1180, y: 540, space: "virtual-desktop-px", kind: "agent", agentId: "session-2", agentLabel: "Cursor", state: "locked", confidence: 0.9, ts: 1000),
        ]))
    }
}
#endif
