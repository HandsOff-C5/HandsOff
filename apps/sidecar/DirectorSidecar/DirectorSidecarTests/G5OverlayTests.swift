//
//  G5OverlayTests.swift
//  DirectorSidecarTests
//
//  G5 cursor-overlay logic: contract→Cocoa y-flip, the view-point resolver (contract direct vs
//  hugging flip), and the OverlayModel reducer (user hug/point, agent fleet, stale-frame drop,
//  remove-on-absence, poof on runResult).
//

import Testing
import Foundation
import CoreGraphics
@testable import DirectorSidecar

private func pointer(_ kind: String, x: Double, y: Double, id: String? = nil, state: String = "moving", ts: Double = 1) -> Pointer {
    Pointer(x: x, y: y, space: "virtual-desktop-px", kind: kind, agentId: id,
            agentLabel: id.map { "Agent \($0)" }, state: state, confidence: 0.9, ts: ts)
}

// MARK: coordinate conversion (spec test)

@Test func cocoaPointFlipsYAroundPrimary() {
    let p = ScreenGeometry.cocoaPoint(contractX: 300, contractY: 210, primaryMaxY: 900)
    let expectedX: CGFloat = 300
    let expectedY: CGFloat = 690 // 900 - 210
    #expect(p.x == expectedX)
    #expect(p.y == expectedY)
}

@Test func resolvedViewPointPassesContractThroughAndFlipsHug() {
    // Contract target → straight through (SwiftUI is also top-left/y-down).
    let agent = DirectorCursor(id: "a", kind: .agent, label: "A", contractPoint: CGPoint(x: 300, y: 210), state: .moving, confidence: 1, lastTs: 1)
    let p = OverlayModel.resolvedViewPoint(for: agent, systemCursorCocoa: .zero, primaryHeight: 900)
    #expect(p.x == 300 && p.y == 210)

    // Hugging Director cursor → flip the Cocoa system cursor + offset.
    let user = DirectorCursor(id: "user", kind: .user, label: nil, contractPoint: nil, state: .hugging, confidence: 1, lastTs: 0)
    let hug = OverlayModel.resolvedViewPoint(for: user, systemCursorCocoa: CGPoint(x: 500, y: 800), primaryHeight: 900)
    #expect(hug.x == 500 + OverlayModel.hugOffset.width)
    #expect(hug.y == 900 - 800 + OverlayModel.hugOffset.height)
}

// MARK: reducer (main actor)

@MainActor
@Test func activeAddsHuggingDirectorCursor() {
    let model = OverlayModel()
    #expect(model.cursors.isEmpty)
    model.setActive(true)
    #expect(model.cursors.count == 1)
    #expect(model.cursors.first?.kind == .user)
    #expect(model.cursors.first?.state == .hugging)
    #expect(model.cursors.first?.contractPoint == nil) // hugs, no target
    model.setActive(false)
    #expect(model.cursors.isEmpty)
}

@MainActor
@Test func userPointingFrameGivesTargetThenIdleReturnsToHug() {
    let model = OverlayModel()
    model.setActive(true)
    model.apply(.cursor(pointers: [pointer("user", x: 400, y: 300, state: "locked", ts: 2)]))
    let pointing = model.cursors.first { $0.kind == .user }
    #expect(pointing?.state == .locked)
    #expect(pointing?.contractPoint == CGPoint(x: 400, y: 300))

    model.apply(.cursor(pointers: [pointer("user", x: 0, y: 0, state: "idle", ts: 3)]))
    let resting = model.cursors.first { $0.kind == .user }
    #expect(resting?.state == .hugging)
    #expect(resting?.contractPoint == nil) // back to hugging the system cursor
}

@MainActor
@Test func agentFleetRendersMultipleCursors() {
    let model = OverlayModel()
    model.apply(.cursor(pointers: [
        pointer("agent", x: 700, y: 360, id: "session-1", ts: 1),
        pointer("agent", x: 1180, y: 540, id: "session-2", state: "locked", ts: 1),
    ]))
    let agents = model.cursors.filter { $0.kind == .agent }
    #expect(agents.count == 2)
    #expect(agents.contains { $0.id == "session-1" && $0.label == "Agent session-1" })
}

@MainActor
@Test func staleFramesAreDropped() {
    let model = OverlayModel()
    model.apply(.cursor(pointers: [pointer("agent", x: 700, y: 360, id: "s1", ts: 5)]))
    // Older ts for the same id → ignored.
    model.apply(.cursor(pointers: [pointer("agent", x: 100, y: 100, id: "s1", ts: 2)]))
    #expect(model.cursors.first { $0.id == "s1" }?.contractPoint == CGPoint(x: 700, y: 360))
}

@MainActor
@Test func agentAbsentFromFrameIsRemoved() {
    let model = OverlayModel()
    model.apply(.cursor(pointers: [
        pointer("agent", x: 1, y: 1, id: "s1", ts: 1),
        pointer("agent", x: 2, y: 2, id: "s2", ts: 1),
    ]))
    #expect(model.cursors.count == 2)
    model.apply(.cursor(pointers: [pointer("agent", x: 1, y: 1, id: "s1", ts: 2)]))
    #expect(model.cursors.map(\.id) == ["s1"]) // s2 stopped → removed
}

@MainActor
@Test func runResultPoofsAndRemovesAgentCursor() {
    let model = OverlayModel()
    model.apply(.cursor(pointers: [pointer("agent", x: 1, y: 1, id: "s1", ts: 1)]))
    model.apply(.runResult(RunResultPayload(status: .succeeded, sessionId: "s1")))
    #expect(!model.cursors.contains { $0.id == "s1" })
}

@MainActor
@Test func disconnectClearsAllCursors() {
    let model = OverlayModel()
    model.setActive(true)
    model.apply(.cursor(pointers: [pointer("agent", x: 1, y: 1, id: "s1", ts: 1)]))
    model.setConnection(.engineDown)
    #expect(model.cursors.isEmpty) // never a stranded cursor
}
