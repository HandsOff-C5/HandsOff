//
//  DirectorSidecarTests.swift
//  DirectorSidecarTests
//
//  Contract decode tests for the engine-bridge frames. These are the drift guard: if the
//  Rust bridge envelope changes, these fail loudly.
//

import Testing
import Foundation
@testable import DirectorSidecar

@Test func decodesReadinessStateFrame() throws {
    let json = #"{"v":1,"type":"state","topic":"readiness","payload":{"capabilities":[{"id":"camera","kind":"permission","state":"granted"}]}}"#
    guard case let .state(topic, readiness) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected a state frame"); return }
    #expect(topic == "readiness")
    #expect(readiness?.capabilities.first?.id == "camera")
    #expect(readiness?.capabilities.first?.state == "granted")
}

@Test func decodesErrorFrame() throws {
    let json = #"{"v":1,"type":"error","topic":"error","payload":{"reason":"unknown-topic"}}"#
    guard case let .error(reason) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected an error frame"); return }
    #expect(reason == "unknown-topic")
}

@Test func rejectsUnsupportedVersion() {
    let json = #"{"v":2,"type":"state","topic":"readiness","payload":{"capabilities":[]}}"#
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    }
}
