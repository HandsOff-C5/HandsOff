//
//  G1StoreTests.swift
//  DirectorSidecarTests
//
//  G1 state-model logic: readiness derivation, canListen gating, MenuSession mapping, and the
//  reconnect backoff schedule. All pure/nonisolated — no live socket.
//

import Testing
import Foundation
@testable import DirectorSidecar

private func cap(_ id: String, _ state: String) -> CapabilityProbe {
    CapabilityProbe(id: id, kind: "permission", state: state)
}

// MARK: readiness derivation

@Test func readinessIsReadyWhenListenCapsGranted() {
    let caps = [cap("microphone", "granted"), cap("speech-recognition", "granted")]
    #expect(BridgeStore.readinessLevel(for: caps) == .ready)
}

@Test func readinessIsBlockedWhenAListenCapDenied() {
    let caps = [cap("microphone", "denied"), cap("speech-recognition", "granted")]
    #expect(BridgeStore.readinessLevel(for: caps) == .blocked)
}

@Test func readinessIsAttentionWhenNotDeterminedOrMissing() {
    #expect(BridgeStore.readinessLevel(for: [cap("microphone", "not-determined"), cap("speech-recognition", "granted")]) == .attention)
    #expect(BridgeStore.readinessLevel(for: []) == .attention) // both missing
}

@Test func readinessLabelsMatchLevels() {
    #expect(BridgeStore.readinessLabel(for: .ready) == "Listening ready")
    #expect(BridgeStore.readinessLabel(for: .attention) == "Attention")
    #expect(BridgeStore.readinessLabel(for: .blocked) == "Blocked")
}

// MARK: canListen gating

@Test func canListenRequiresGrantedCapsAndConnected() {
    let granted = [cap("microphone", "granted"), cap("speech-recognition", "granted")]
    #expect(BridgeStore.canListen(caps: granted, connection: .connected))
    #expect(!BridgeStore.canListen(caps: granted, connection: .engineDown))   // not connected
    #expect(!BridgeStore.canListen(caps: granted, connection: .connecting))
    let denied = [cap("microphone", "denied"), cap("speech-recognition", "granted")]
    #expect(!BridgeStore.canListen(caps: denied, connection: .connected))     // mic denied
}

// MARK: MenuSession mapping

@Test func menuSessionUsesEnrichmentWhenPresent() {
    let session = SupervisionSession(
        id: "session-3", status: .running,
        startedAt: "2026-06-24T18:00:00.000Z", updatedAt: "2026-06-24T18:00:00.000Z",
        finishedAt: nil, title: "Refactor auth", agentLabel: "Claude Code"
    )
    let menu = MenuSession(session)
    #expect(menu.title == "Refactor auth")
    #expect(menu.agentLabel == "Claude Code")
    #expect(menu.status == .running)
    #expect(menu.startedAt.timeIntervalSince1970 > 0) // ISO parsed, not epoch-0 fallback
}

@Test func menuSessionFallsBackWhenEnrichmentMissing() {
    let session = SupervisionSession(
        id: "session-9", status: .queued,
        startedAt: "not-a-date", updatedAt: "x", finishedAt: nil, title: nil, agentLabel: nil
    )
    let menu = MenuSession(session)
    #expect(menu.title == "Session session-9")
    #expect(menu.agentLabel == "Agent")
    #expect(menu.startedAt == Date(timeIntervalSince1970: 0)) // unparseable → epoch fallback
}

// MARK: reconnect backoff

@Test func backoffClimbsThenCapsAtFiveSeconds() {
    #expect(BridgeConnection.backoffDelay(attempt: 1) == .milliseconds(250))
    #expect(BridgeConnection.backoffDelay(attempt: 2) == .milliseconds(500))
    #expect(BridgeConnection.backoffDelay(attempt: 3) == .milliseconds(1000))
    #expect(BridgeConnection.backoffDelay(attempt: 5) == .milliseconds(4000))
    #expect(BridgeConnection.backoffDelay(attempt: 6) == .milliseconds(5000)) // capped
    #expect(BridgeConnection.backoffDelay(attempt: 99) == .milliseconds(5000))
}

// MARK: store frame application (main-actor)

@MainActor
@Test func applyingSessionsThenRunResultFlipsRowAndCount() {
    let store = BridgeStore()
    let payload = SessionsPayload(
        sessions: [
            SupervisionSession(id: "a", status: .running, startedAt: "t", updatedAt: "t", finishedAt: nil, title: "A", agentLabel: "Claude Code"),
            SupervisionSession(id: "b", status: .running, startedAt: "t", updatedAt: "t", finishedAt: nil, title: "B", agentLabel: "Cursor"),
        ],
        counts: nil
    )
    store.apply(.sessions(payload))
    #expect(store.sessions.count == 2)
    #expect(store.runningCount == 2)

    store.apply(.runResult(RunResultPayload(status: .succeeded, sessionId: "b")))
    #expect(store.sessions.first(where: { $0.id == "b" })?.status == .succeeded)
    #expect(store.runningCount == 1) // decremented live
    #expect(store.doneCount == 1)
}
