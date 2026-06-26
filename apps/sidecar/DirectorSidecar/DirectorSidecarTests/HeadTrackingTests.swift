//
//  HeadTrackingTests.swift
//  DirectorSidecarTests
//
//  Ported from src-tauri/sidecars/head-track/HeadTrackSelfTest.swift (ADR 0005 test gate: sidecar
//  self-tests must be replaced by Xcode tests when the service is folded in). Covers the pure logic:
//  active-face selection, signal extraction + frame gate, pointer motion response curve, periodic
//  recenter, no-face recovery, the AppKit→top-left coordinate flip, and the typed-event invariants
//  that replaced the JSON wire (confidence clamp, optional yaw). The deleted stdin control-parsing
//  self-test (`testControlCommandParsing`) is intentionally NOT ported — that seam no longer exists.
//

import Testing
import Foundation
import CoreGraphics
@testable import DirectorSidecar

// MARK: helpers

private func expectClose(_ actual: Double, _ expected: Double, tolerance: Double, _ message: String) {
    #expect(abs(actual - expected) <= tolerance, "\(message)")
}

private func makeSignal(x: Double, y: Double = 0, confidence: Double = 0.9) -> HeadSignal {
    HeadSignal(
        faceBox: CGRect(x: 0.3 + x * 0.02, y: 0.3, width: 0.25, height: 0.35),
        faceCenter: CGPoint(x: 0.425 + x * 0.02, y: 0.475),
        eyeMidpoint: CGPoint(x: 0.425, y: 0.55),
        eyeDistance: 0.22,
        noseOffset: CGPoint(x: x, y: y),
        roll: 0,
        yaw: x * 0.2,
        pitch: y * 0.2,
        confidence: confidence
    )
}

// MARK: active-face selection

@Test func activeFaceSelectionResistsAndReacquires() {
    var tracker = ActiveFaceTracker()
    let current = FaceCandidate(id: "current", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.25, height: 0.35), confidence: 0.72)
    let slightCompetitor = FaceCandidate(id: "competitor", boundingBox: CGRect(x: 0.65, y: 0.2, width: 0.25, height: 0.35), confidence: 0.79)
    let clearCompetitor = FaceCandidate(id: "winner", boundingBox: CGRect(x: 0.65, y: 0.2, width: 0.25, height: 0.35), confidence: 0.98)

    #expect(tracker.choose(from: [current])?.id == "current", "one valid face becomes active")
    #expect(tracker.choose(from: [slightCompetitor, current])?.id == "current", "active face resists slight confidence wins")
    #expect(tracker.choose(from: [slightCompetitor]) == nil, "short active-face dropout holds instead of switching")
    #expect(tracker.choose(from: [slightCompetitor]) == nil, "second active-face dropout still holds")
    #expect(tracker.choose(from: [slightCompetitor])?.id == "competitor", "lost active face reacquires best candidate")

    tracker = ActiveFaceTracker()
    _ = tracker.choose(from: [current])
    tracker.accept(makeSignal(x: 0))
    #expect(tracker.predictedBox != nil, "accepted active face predicts the next box")
    let farReentry = FaceCandidate(id: "far-reentry", boundingBox: CGRect(x: 0.78, y: 0.2, width: 0.18, height: 0.3), confidence: 0.9)
    #expect(tracker.choose(from: [farReentry]) == nil, "first far jump waits for lost budget")
    #expect(tracker.choose(from: [farReentry]) == nil, "second far jump still waits for lost budget")
    #expect(tracker.choose(from: [farReentry])?.id == "far-reentry", "far jump reacquires after lost budget")
    #expect(tracker.predictedBox == nil, "fresh reacquisition does not use stale box prediction")

    tracker = ActiveFaceTracker()
    #expect(tracker.choose(from: [current])?.id == "current", "active face reset selects current")
    #expect(tracker.choose(from: [clearCompetitor, current])?.id == "winner", "clear competitor can take over")
}

// MARK: signal extraction + frame gate

@Test func signalExtractionAndFrameGate() {
    let face = FaceCandidate(id: "face", boundingBox: CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.4), confidence: 0.9)
    let landmarks = LandmarkInput(
        face: face,
        leftEye: [CGPoint(x: 0.30, y: 0.55)],
        rightEye: [CGPoint(x: 0.54, y: 0.55)],
        nose: [CGPoint(x: 0.44, y: 0.43)],
        yaw: 0.1,
        pitch: -0.05
    )
    let signal = extractSignal(from: landmarks)!
    expectClose(signal.eyeDistance, 0.24, tolerance: 0.001, "inter-eye distance is measured")
    expectClose(signal.noseOffset.x, 0.02 / 0.24, tolerance: 0.002, "nose x offset is eye-distance normalized")
    expectClose(signal.roll, 0, tolerance: 0.001, "level eyes produce zero roll")

    let closer = FaceCandidate(id: "face", boundingBox: CGRect(x: 0.15, y: 0.2, width: 0.45, height: 0.55), confidence: 0.9)
    let closerSignal = extractSignal(from: LandmarkInput(
        face: closer,
        leftEye: [CGPoint(x: 0.30, y: 0.55)],
        rightEye: [CGPoint(x: 0.54, y: 0.55)],
        nose: [CGPoint(x: 0.44, y: 0.43)],
        yaw: 0.1,
        pitch: -0.05
    ))!
    expectClose(closerSignal.noseOffset.x, signal.noseOffset.x, tolerance: 0.001, "scale alone does not change normalized nose offset")

    #expect(extractSignal(from: LandmarkInput(face: face, leftEye: nil, rightEye: landmarks.rightEye, nose: landmarks.nose, yaw: nil, pitch: nil)) == nil, "missing eye landmarks reject extraction")

    let gate = FrameGate()
    #expect(gate.accepts(signal, previous: nil, predictedBox: nil), "first valid signal is accepted")
    let lowConfidence = HeadSignal(signal, confidence: 0.2)
    #expect(!gate.accepts(lowConfidence, previous: signal, predictedBox: signal.faceBox), "low-confidence frame is rejected")
    let jumped = HeadSignal(signal, faceBox: CGRect(x: 0.75, y: 0.25, width: 0.3, height: 0.4))
    #expect(!gate.accepts(jumped, previous: signal, predictedBox: signal.faceBox), "implausible face-box jump is rejected")
    let scaled = HeadSignal(signal, faceBox: CGRect(x: 0.2, y: 0.25, width: 0.55, height: 0.75), eyeDistance: signal.eyeDistance * 2.1)
    #expect(!gate.accepts(scaled, previous: signal, predictedBox: signal.faceBox), "implausible scale change is rejected")
}

// MARK: pointer motion

@Test func pointerMotionResponseCurve() {
    let screen = CGRect(x: 0, y: 0, width: 500, height: 500)
    var pointer = HeadPointerMotion(config: .default)

    let first = pointer.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])!
    for frame in 1...30 {
        let jitter = pointer.step(signal: makeSignal(x: frame.isMultiple(of: 2) ? 0.015 : -0.012), timestamp: Double(frame) / 30, screens: [screen])!
        expectClose(jitter.x, first.x, tolerance: 0.5, "neutral jitter does not move pointer")
    }

    let slowStart = pointer.step(signal: makeSignal(x: 0.16), timestamp: 1.1, screens: [screen])!
    let slowEnd = pointer.step(signal: makeSignal(x: 0.18), timestamp: 1.2, screens: [screen])!
    let slowDelta = slowEnd.x - slowStart.x
    let fastStart = pointer.step(signal: makeSignal(x: 0.42), timestamp: 1.3, screens: [screen])!
    let fastEnd = pointer.step(signal: makeSignal(x: 0.55), timestamp: 1.4, screens: [screen])!
    let fastDelta = fastEnd.x - fastStart.x
    #expect(fastDelta > slowDelta * 2, "larger faster movement accelerates more than slow movement")

    let hysteresisHold = pointer.step(signal: makeSignal(x: 0.08), timestamp: 1.5, screens: [screen])!
    #expect(hysteresisHold.x > slowEnd.x, "outer-to-inner hysteresis keeps movement active")
    let stopped = pointer.step(signal: makeSignal(x: 0.01), timestamp: 1.6, screens: [screen])!
    expectClose(stopped.x, hysteresisHold.x, tolerance: 0.5, "inner hysteresis band stops movement")

    pointer.requestRecenter()
    let recentered = pointer.step(signal: makeSignal(x: 0.35), timestamp: 1.7, screens: [screen])!
    expectClose(recentered.x, 250, tolerance: 0.5, "manual recenter centers pointer")
    let afterRecenter = pointer.step(signal: makeSignal(x: 0.35), timestamp: 1.8, screens: [screen])!
    expectClose(afterRecenter.x, recentered.x, tolerance: 0.5, "new neutral holds after recenter")

    var clamped = HeadPointerMotion(config: HeadPointerConfig(movementMode: .edge, speed: 30, distanceToEdge: 0.04))
    _ = clamped.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    let nearEdge = clamped.step(signal: makeSignal(x: 2), timestamp: 2, screens: [screen, CGRect(x: 800, y: 0, width: 500, height: 500)])!
    #expect(HeadGeometry.containsInclusive(screen, nearEdge) || HeadGeometry.containsInclusive(CGRect(x: 800, y: 0, width: 500, height: 500), nearEdge), "integrated pointer clamps into a real screen")

    var relative = HeadPointerMotion(config: HeadPointerConfig(movementMode: .relative, speed: 5, distanceToEdge: 0.12))
    _ = relative.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    let relativeMove = relative.step(signal: makeSignal(x: 0.45), timestamp: 0.2, screens: [screen])!
    #expect(relativeMove.x > 250, "relative mode moves from face translation")
}

@Test func periodicRecenterOnlyWhileStable() {
    let screen = CGRect(x: 0, y: 0, width: 500, height: 500)
    var stable = HeadPointerMotion(config: .default)
    _ = stable.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    for frame in 1...150 {
        _ = stable.step(signal: makeSignal(x: 0.04), timestamp: Double(frame) / 30, screens: [screen])
    }
    #expect((stable.neutralNoseOffsetXForSelfTest ?? 0) > 0, "stable in-band drift can slowly update neutral")

    var active = HeadPointerMotion(config: .default)
    _ = active.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    for frame in 1...150 {
        _ = active.step(signal: makeSignal(x: 0.4), timestamp: Double(frame) / 30, screens: [screen])
    }
    expectClose(active.neutralNoseOffsetXForSelfTest ?? -1, 0, tolerance: 0.0001, "active movement does not drag neutral")
}

@Test func modelRecoversAfterNoFaceGap() {
    let screen = CGRect(x: 0, y: 0, width: 500, height: 500)
    var model = HeadTrackingModel()
    let initial = makeSignal(x: 0)
    let initialFace = FaceCandidate(id: "initial", boundingBox: initial.faceBox, confidence: 0.9)
    #expect(model.chooseFace(from: [initialFace])?.id == "initial", "model selects initial face")
    #expect(model.point(for: initial, timestamp: 0, screens: [screen]) != nil, "initial face produces a point")

    for _ in 0..<3 {
        #expect(model.chooseFace(from: []) == nil, "missing face produces no candidate")
        model.missFace()
    }

    let returned = HeadSignal(
        makeSignal(x: 0.02),
        faceBox: CGRect(x: 0.78, y: 0.2, width: 0.18, height: 0.3),
        eyeDistance: 0.09
    )
    let returnedFace = FaceCandidate(id: "returned", boundingBox: returned.faceBox, confidence: 0.9)
    #expect(model.chooseFace(from: [returnedFace])?.id == "returned", "model reacquires after a no-face gap")
    #expect(model.point(for: returned, timestamp: 1, screens: [screen]) != nil, "freshly reacquired face is not rejected by stale geometry")
}

// MARK: coordinate flip

@Test func appKitToGlobalTopLeftFlip() {
    let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // Bottom of the primary screen (AppKit y = 0) maps to the bottom in CG (y = height).
    let bottom = HeadGeometry.appKitToGlobalTopLeft(CGPoint(x: 200, y: 0), screens: [primary])
    expectClose(bottom.x, 200, tolerance: 0.001, "x is preserved by the top-left flip")
    expectClose(bottom.y, 982, tolerance: 0.001, "AppKit bottom maps to CG bottom edge")

    // Top of the primary screen (AppKit y = height) maps to the CG origin (y = 0).
    let top = HeadGeometry.appKitToGlobalTopLeft(CGPoint(x: 200, y: 982), screens: [primary])
    expectClose(top.y, 0, tolerance: 0.001, "AppKit top maps to CG top origin")

    // The flip pivots on the PRIMARY display's height even for a screen stacked above it.
    let stacked = [primary, CGRect(x: 0, y: 982, width: 1512, height: 800)]
    let above = HeadGeometry.appKitToGlobalTopLeft(CGPoint(x: 10, y: 1500), screens: stacked)
    expectClose(above.y, -518, tolerance: 0.001, "point above the primary maps to negative CG y")
}

@Test func clampGapPointIntoRealScreen() {
    let primary = CGRect(x: 0, y: 0, width: 100, height: 100)
    let secondary = CGRect(x: 200, y: 0, width: 100, height: 100)
    let clamped = HeadGeometry.clampIntoRealScreen(CGPoint(x: 150, y: 50), screens: [primary, secondary])
    #expect(HeadGeometry.containsInclusive(primary, clamped) || HeadGeometry.containsInclusive(secondary, clamped), "gap point clamps into a real screen")
}

// MARK: typed event invariants (replacing the JSON wire self-tests)

@Test func headPointClampsConfidenceAndKeepsOptionalAngles() {
    // The wire `pointEvent` clamped confidence to 0…1 and serialized nil yaw/pitch as null.
    let clampedHigh = HeadPoint(x: 1, y: 2, yaw: nil, pitch: 0.1, confidence: 2, ts: 123)
    #expect(clampedHigh.confidence == 1, "confidence is clamped to the wire range upper bound")
    #expect(clampedHigh.yaw == nil, "nil yaw is preserved, not substituted")
    #expect(clampedHigh.pitch == 0.1, "present pitch passes through")

    let clampedLow = HeadPoint(x: 0, y: 0, yaw: -0.3, pitch: nil, confidence: -5, ts: 1)
    #expect(clampedLow.confidence == 0, "confidence is clamped to the wire range lower bound")
    #expect(clampedLow.pitch == nil, "nil pitch is preserved")
}
