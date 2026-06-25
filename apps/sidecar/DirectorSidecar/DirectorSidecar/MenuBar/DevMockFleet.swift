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

    /// Feed canned frames to every model via `dispatch` (no socket). Drives the menu fleet AND
    /// the HUD loop (transcript → referents → read-only intent → runResult) so both surfaces are
    /// demoable before the engine publishes. One agent finishes live to show the count decrement.
    @MainActor
    static func drive(
        dispatch: @escaping (BridgeFrame) -> Void,
        setState: @escaping (ConnectionState) -> Void,
        activate: @escaping (Bool) -> Void,
        select: @escaping (String) -> Void,
        now: Date
    ) async {
        setState(.connected)
        dispatch(.state(topic: "readiness", readiness: allCapsGranted))
        dispatch(.sessions(fleet(now: now)))

        activate(true) // fn-active → the three overlays come up (Director cursor + brackets)

        // G7 eye-gaze brackets morph: a small control → a larger block (eased, not snapped).
        dispatch(.gaze(GazeFocus(bounds: GazeRegion(x: 380, y: 240, w: 120, h: 36), confidence: 0.92, sizeClass: "element", ts: 100)))
        try? await Task.sleep(for: .seconds(1.4))
        dispatch(.gaze(GazeFocus(bounds: GazeRegion(x: 320, y: 300, w: 460, h: 220), confidence: 0.9, sizeClass: "block", ts: 200)))

        // HUD read-only loop (G2a): a read_only intent that auto-runs (no footer).
        try? await Task.sleep(for: .seconds(1.2))
        dispatch(.transcript(TranscriptEvent(kind: "partial", text: "summarize that issue", confidence: 0.9, latencyMs: 120, receivedAt: 0)))
        try? await Task.sleep(for: .seconds(0.8))
        dispatch(.transcript(TranscriptEvent(kind: "final", text: "summarize that issue", confidence: 0.96, latencyMs: 140, receivedAt: 0)))
        dispatch(.referents(ReferentsPayload(
            surfaces: [SurfaceSnapshot(id: "win-1", title: "#42 Flaky CUA test", app: "GitHub", pid: nil, windowId: nil, availability: "available", accessStatus: "granted")],
            selected: SelectedReferent(id: "win-1", source: "point", confidence: 0.9)
        )))
        try? await Task.sleep(for: .seconds(1))
        select("session-1") // bind the Inspector to the running agent (G4b)
        if isDestructive {
            // Destructive → optional Greenlight footer renders + stays (awaitingGreenlight).
            dispatch(.intent(ResolvedIntentLite(
                id: "intent-9", status: .ready, intentType: "delete", riskLevel: .destructive,
                requiresApproval: true, summary: "Delete everything in ~/Documents", reason: nil,
                steps: [
                    ActionStepLite(id: "s1", label: "Empty the Documents folder", kind: "set_value", targetTitle: "Finder", proposed: "(removes 412 files)"),
                ]
            )))
            return
        }
        dispatch(.intent(ResolvedIntentLite(
            id: "intent-1", status: .ready, intentType: "summarize", riskLevel: .readOnly,
            requiresApproval: false, summary: "Summarize GitHub issue 42", reason: nil,
            steps: [
                ActionStepLite(id: "s1", label: "Read the issue thread", kind: "inspect_window_state", targetTitle: "GitHub — Issue 42", proposed: nil),
                ActionStepLite(id: "s2", label: "Type the summary into Notes", kind: "type_text", targetTitle: "Notes", proposed: "TL;DR: flaky CUA test, fix the await race."),
            ]
        )))
        try? await Task.sleep(for: .seconds(1))
        // Agent-working: two agent cursors traveling (the AI-engineer Supervise fleet).
        dispatch(.cursor(pointers: [
            Pointer(x: 720, y: 360, space: "virtual-desktop-px", kind: "agent", agentId: "session-1", agentLabel: "Claude Code", state: "moving", confidence: 0.95, ts: 1000),
            Pointer(x: 1180, y: 540, space: "virtual-desktop-px", kind: "agent", agentId: "session-2", agentLabel: "Cursor", state: "locked", confidence: 0.9, ts: 1000),
        ]))
        try? await Task.sleep(for: .seconds(2))
        dispatch(.runResult(RunResultPayload(status: .succeeded, sessionId: "session-2")))
    }
}
#endif
