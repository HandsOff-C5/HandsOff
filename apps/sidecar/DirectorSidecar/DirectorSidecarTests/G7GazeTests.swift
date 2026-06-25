//
//  G7GazeTests.swift
//  DirectorSidecarTests
//
//  G7 eye-gaze brackets: gazeFocus decode/drift, contract→Cocoa rect y-flip, and the
//  GazeBracketModel (active gating, morph, latest-per-ts smoothing, low-confidence hold,
//  confirm-on-referent, hide-on-inactive/disconnect).
//

import Testing
import Foundation
import CoreGraphics
@testable import DirectorSidecar

// MARK: decode

@Test func decodesGazeFocusFrame() throws {
    let json = #"{"v":1,"type":"state","topic":"gazeFocus","payload":{"bounds":{"x":320,"y":300,"w":460,"h":220},"confidence":0.9,"sizeClass":"block","ts":1719240000000}}"#
    guard case let .gaze(focus) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected a gaze frame"); return }
    #expect(focus.bounds.w == 460)
    #expect(focus.confidence == 0.9)
    #expect(focus.sizeClass == "block")
}

@Test func gazeFocusToleratesMissingSizeClass() throws {
    let json = #"{"v":1,"type":"state","topic":"gazeFocus","payload":{"bounds":{"x":1,"y":2,"w":3,"h":4},"confidence":0.8,"ts":5}}"#
    guard case let .gaze(focus) = try JSONDecoder().decode(BridgeFrame.self, from: Data(json.utf8))
    else { Issue.record("expected a gaze frame"); return }
    #expect(focus.sizeClass == nil)
}

// MARK: coordinate conversion

@Test func cocoaRectFlipsYAroundBottom() {
    // contract rect origin is top-left; Cocoa origin is bottom-left → y = maxY - (y + h).
    let r = ScreenGeometry.cocoaRect(x: 100, y: 50, w: 200, h: 80, primaryMaxY: 900)
    let expectedX: CGFloat = 100
    let expectedY: CGFloat = 900 - (50 + 80) // 770
    #expect(r.origin.x == expectedX)
    #expect(r.origin.y == expectedY)
    #expect(r.width == 200)
    #expect(r.height == 80)
}

// MARK: model (main actor)

private func gaze(_ x: Double, _ y: Double, _ w: Double, _ h: Double, conf: Double = 0.9, ts: Double) -> BridgeFrame {
    .gaze(GazeFocus(bounds: GazeRegion(x: x, y: y, w: w, h: h), confidence: conf, sizeClass: nil, ts: ts))
}

@MainActor
@Test func bracketsHiddenUntilActive() {
    let model = GazeBracketModel()
    model.apply(gaze(0, 0, 10, 10, ts: 1)) // ignored while inactive
    #expect(model.phase == .hidden)
    #expect(!model.isVisible)
}

@MainActor
@Test func bracketsTrackThenMorphWhenActive() {
    let model = GazeBracketModel()
    model.setActive(true)
    model.apply(gaze(380, 240, 120, 36, ts: 1))
    #expect(model.phase == .tracking)
    #expect(model.region == GazeRegion(x: 380, y: 240, w: 120, h: 36))

    model.apply(gaze(320, 300, 460, 220, ts: 2)) // new region → morph
    #expect(model.phase == .morphing)
    #expect(model.region?.w == 460)
}

@MainActor
@Test func staleGazeFramesAreDropped() {
    let model = GazeBracketModel()
    model.setActive(true)
    model.apply(gaze(320, 300, 460, 220, ts: 5))
    model.apply(gaze(0, 0, 10, 10, ts: 2)) // older ts → ignored (smoothing)
    #expect(model.region?.w == 460)
}

@MainActor
@Test func lowConfidenceHoldsLastGoodRect() {
    let model = GazeBracketModel()
    model.setActive(true)
    model.apply(gaze(320, 300, 460, 220, conf: 0.9, ts: 1))
    model.apply(gaze(10, 10, 20, 20, conf: 0.2, ts: 2)) // uncertain → hold last good, just dim
    #expect(model.phase == .lowConfidence)
    #expect(model.isDim)
    #expect(model.region?.w == 460) // did NOT chase the low-confidence guess
}

@MainActor
@Test func confirmsOnSelectedReferent() {
    let model = GazeBracketModel()
    model.setActive(true)
    model.apply(gaze(320, 300, 460, 220, ts: 1))
    model.apply(.referents(ReferentsPayload(surfaces: [], selected: SelectedReferent(id: "r1", source: "gaze", confidence: 0.9))))
    #expect(model.phase == .confirmed)
}

@MainActor
@Test func inactiveAndDisconnectHideBrackets() {
    let model = GazeBracketModel()
    model.setActive(true)
    model.apply(gaze(1, 1, 1, 1, ts: 1))
    #expect(model.isVisible)
    model.setActive(false)
    #expect(model.phase == .hidden)
    #expect(model.region == nil)

    model.setActive(true)
    model.apply(gaze(1, 1, 1, 1, ts: 2))
    model.setConnection(.engineDown)
    #expect(model.phase == .hidden) // never stranded brackets
}
