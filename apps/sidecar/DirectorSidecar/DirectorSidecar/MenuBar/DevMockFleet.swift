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
        ProcessInfo.processInfo.environment["DIRECTOR_MOCK_FLEET"] == "1"
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
        now: Date
    ) async {
        setState(.connected)
        dispatch(.state(topic: "readiness", readiness: allCapsGranted))
        dispatch(.sessions(fleet(now: now)))

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
        dispatch(.intent(ResolvedIntentLite(status: .ready, intentType: "summarize", riskLevel: .readOnly, requiresApproval: false, summary: "Summarize GitHub issue #42", reason: nil)))
        try? await Task.sleep(for: .seconds(2))
        dispatch(.runResult(RunResultPayload(status: .succeeded, sessionId: "session-2")))
    }
}
#endif
