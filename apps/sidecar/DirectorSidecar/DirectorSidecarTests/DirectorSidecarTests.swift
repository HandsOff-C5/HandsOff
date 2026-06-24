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

@Test func decodesAgentCursorFrame() throws {
    let json = #"{"v":1,"type":"state","topic":"cursorPosition","payload":{"pointers":[{"x":1280,"y":40,"space":"virtual-desktop-px","kind":"agent","agentId":"sess-1","agentLabel":"Claude Code","state":"moving","confidence":0.9,"ts":1719240000000}]}}"#
    guard case let .cursor(pointers) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected a cursor frame"); return }
    #expect(pointers.count == 1)
    let p = pointers[0]
    #expect(p.kind == "agent")
    #expect(p.agentLabel == "Claude Code")
    #expect(p.x == 1280 && p.y == 40)
    #expect(p.state == "moving")
}

@Test func decodesUserReticlePointerWithNegativeOffset() throws {
    // kind:"user" carries no agent fields; negative x = a monitor left of the primary display.
    let json = #"{"v":1,"type":"state","topic":"cursorPosition","payload":{"pointers":[{"x":-200,"y":900,"space":"virtual-desktop-px","kind":"user","state":"locked","ts":1719240000001}]}}"#
    guard case let .cursor(pointers) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected a cursor frame"); return }
    #expect(pointers.first?.kind == "user")
    #expect(pointers.first?.agentId == nil)
    #expect(pointers.first?.x == -200)
}
