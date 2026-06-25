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

    /// Feed canned frames into the store (no socket). Simulates one agent finishing live so the
    /// runResult path (count decrement) is visible while the popover is open.
    @MainActor
    static func drive(_ store: BridgeStore, now: Date) async {
        store.setConnection(.connected)
        store.apply(.state(topic: "readiness", readiness: allCapsGranted))
        store.apply(.sessions(fleet(now: now)))
        try? await Task.sleep(for: .seconds(8))
        store.apply(.runResult(RunResultPayload(status: .succeeded, sessionId: "session-2")))
    }
}
#endif
