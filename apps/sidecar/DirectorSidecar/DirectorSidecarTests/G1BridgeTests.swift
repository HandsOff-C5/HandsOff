//
//  G1BridgeTests.swift
//  DirectorSidecarTests
//
//  G1 wire drift guards: sessions/runResult decode (T-G1.3), Swift-side count derivation,
//  command encoding (§4.2), and handshake resolution (T-G1.4 sidecar half). Inline JSON
//  mirrors the @handsoff/supervision + @handsoff/contracts shapes; if those drift, these fail.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: sessions / runResult decode

@Test func decodesSessionsFrameWithEngineCounts() throws {
    let json = #"{"v":1,"type":"state","topic":"sessions","payload":{"sessions":[{"id":"session-1","status":"running","startedAt":"2026-06-24T18:00:00.000Z","updatedAt":"2026-06-24T18:01:00.000Z"}],"counts":{"running":1,"needsGreenlight":0,"done":0}}}"#
    guard case let .sessions(payload) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected a sessions frame"); return }
    #expect(payload.sessions.count == 1)
    #expect(payload.sessions.first?.id == "session-1")
    #expect(payload.sessions.first?.status == .running)
    #expect(payload.resolvedCounts.running == 1)
}

@Test func derivesCountsWhenEngineOmitsThem() throws {
    let json = #"{"v":1,"type":"state","topic":"sessions","payload":{"sessions":[{"id":"s1","status":"running","startedAt":"t","updatedAt":"t"},{"id":"s2","status":"blocked","startedAt":"t","updatedAt":"t"},{"id":"s3","status":"succeeded","startedAt":"t","updatedAt":"t","finishedAt":"t"}]}}"#
    guard case let .sessions(payload) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected a sessions frame"); return }
    #expect(payload.counts == nil)
    let c = payload.resolvedCounts
    #expect(c.running == 1)
    #expect(c.needsGreenlight == 1) // blocked == awaiting (destructive) approval
    #expect(c.done == 1)            // succeeded
}

@Test func decodesRunResultFrame() throws {
    let json = #"{"v":1,"type":"state","topic":"runResult","payload":{"status":"succeeded","sessionId":"session-1"}}"#
    guard case let .runResult(p) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected a runResult frame"); return }
    #expect(p.status == .succeeded)
    #expect(p.sessionId == "session-1")
}

@Test func unknownExecutionStatusFailsLoudly() {
    // `paused` is cut for the demo; an unknown status must fail the frame (drift-loud),
    // not silently mis-render. The connection layer drops the bad frame, keeps last-good.
    let json = #"{"v":1,"type":"state","topic":"sessions","payload":{"sessions":[{"id":"s1","status":"paused","startedAt":"t","updatedAt":"t"}]}}"#
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    }
}

// MARK: command encoding (§4.2)

private func encodedObject(_ command: Command) throws -> [String: Any] {
    let data = try command.frameData()
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

@Test func encodesEmptyCommandEnvelope() throws {
    let obj = try encodedObject(.commit)
    #expect(obj["v"] as? Int == 1)
    #expect(obj["type"] as? String == "command")
    #expect(obj["topic"] as? String == "commit")
    #expect((obj["payload"] as? [String: Any])?.isEmpty == true)
}

@Test func encodesSelectSessionPayload() throws {
    let obj = try encodedObject(.selectSession("session-7"))
    #expect(obj["topic"] as? String == "selectSession")
    #expect((obj["payload"] as? [String: Any])?["sessionId"] as? String == "session-7")
}

@Test func encodesGreenlightApprovalDecision() throws {
    let obj = try encodedObject(.greenlight(actionId: "act-1", decidedAt: "2026-06-24T00:00:00Z"))
    #expect(obj["topic"] as? String == "greenlight")
    let payload = obj["payload"] as? [String: Any]
    #expect(payload?["decision"] as? String == "approved")
    #expect(payload?["actionId"] as? String == "act-1")
    #expect(payload?["decidedAt"] as? String == "2026-06-24T00:00:00Z")
}

// MARK: handshake (T-G1.4 sidecar half)

@Test func handshakeResolvesValidFile() {
    let json = #"{"port":52345,"token":"abc123","schema":1}"#
    let endpoint = BridgeHandshake.resolve(from: Data(json.utf8))
    #expect(endpoint.host == "127.0.0.1")
    #expect(endpoint.port == 52345)
    #expect(endpoint.token == "abc123")
}

@Test func handshakeFallsBackWhenAbsent() {
    #expect(BridgeHandshake.resolve(from: nil) == BridgeHandshake.fallback)
    #expect(BridgeHandshake.fallback.port == 51703)
    #expect(BridgeHandshake.fallback.token == nil)
}

@Test func handshakeFallsBackOnMalformedOrWrongSchema() {
    #expect(BridgeHandshake.resolve(from: Data("not json".utf8)) == BridgeHandshake.fallback)
    let wrongSchema = #"{"port":52345,"token":"x","schema":2}"#
    #expect(BridgeHandshake.resolve(from: Data(wrongSchema.utf8)) == BridgeHandshake.fallback)
}
