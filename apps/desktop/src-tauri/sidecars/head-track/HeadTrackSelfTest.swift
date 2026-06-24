import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Vision

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    let passed = condition()
    assert(passed, message)
    if !passed {
        fatalError(message)
    }
}

func expectEvent(_ event: [String: Any], kind: String, keys: Set<String>) {
    expect(Set(event.keys) == keys, "\(kind) event has exact wire fields")
    expect(event["kind"] as? String == kind, "\(kind) event kind is stable")
    expect(JSONSerialization.isValidJSONObject(event), "\(kind) event is JSON serializable")
}

func expectClose(_ actual: Double, _ expected: Double, tolerance: Double, _ message: String) {
    expect(abs(actual - expected) <= tolerance, message)
}

func testActiveFaceSelection() {
    var tracker = ActiveFaceTracker()
    let current = FaceCandidate(id: "current", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.25, height: 0.35), confidence: 0.72)
    let slightCompetitor = FaceCandidate(id: "competitor", boundingBox: CGRect(x: 0.65, y: 0.2, width: 0.25, height: 0.35), confidence: 0.79)
    let clearCompetitor = FaceCandidate(id: "winner", boundingBox: CGRect(x: 0.65, y: 0.2, width: 0.25, height: 0.35), confidence: 0.98)

    expect(tracker.choose(from: [current])?.id == "current", "one valid face becomes active")
    expect(tracker.choose(from: [slightCompetitor, current])?.id == "current", "active face resists slight confidence wins")
    expect(tracker.choose(from: [slightCompetitor]) == nil, "short active-face dropout holds instead of switching")
    expect(tracker.choose(from: [slightCompetitor]) == nil, "second active-face dropout still holds")
    expect(tracker.choose(from: [slightCompetitor])?.id == "competitor", "lost active face reacquires best candidate")

    tracker = ActiveFaceTracker()
    _ = tracker.choose(from: [current])
    tracker.accept(makeSignal(x: 0))
    expect(tracker.predictedBox != nil, "accepted active face predicts the next box")
    let farReentry = FaceCandidate(id: "far-reentry", boundingBox: CGRect(x: 0.78, y: 0.2, width: 0.18, height: 0.3), confidence: 0.9)
    expect(tracker.choose(from: [farReentry]) == nil, "first far jump waits for lost budget")
    expect(tracker.choose(from: [farReentry]) == nil, "second far jump still waits for lost budget")
    expect(tracker.choose(from: [farReentry])?.id == "far-reentry", "far jump reacquires after lost budget")
    expect(tracker.predictedBox == nil, "fresh reacquisition does not use stale box prediction")

    tracker = ActiveFaceTracker()
    expect(tracker.choose(from: [current])?.id == "current", "active face reset selects current")
    expect(tracker.choose(from: [clearCompetitor, current])?.id == "winner", "clear competitor can take over")
}

func testSignalExtractionAndFrameGate() {
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

    expect(extractSignal(from: LandmarkInput(face: face, leftEye: nil, rightEye: landmarks.rightEye, nose: landmarks.nose, yaw: nil, pitch: nil)) == nil, "missing eye landmarks reject extraction")

    let gate = FrameGate()
    expect(gate.accepts(signal, previous: nil, predictedBox: nil), "first valid signal is accepted")
    let lowConfidence = HeadSignal(signal, confidence: 0.2)
    expect(!gate.accepts(lowConfidence, previous: signal, predictedBox: signal.faceBox), "low-confidence frame is rejected")
    let jumped = HeadSignal(signal, faceBox: CGRect(x: 0.75, y: 0.25, width: 0.3, height: 0.4))
    expect(!gate.accepts(jumped, previous: signal, predictedBox: signal.faceBox), "implausible face-box jump is rejected")
    let scaled = HeadSignal(signal, faceBox: CGRect(x: 0.2, y: 0.25, width: 0.55, height: 0.75), eyeDistance: signal.eyeDistance * 2.1)
    expect(!gate.accepts(scaled, previous: signal, predictedBox: signal.faceBox), "implausible scale change is rejected")
}

func makeSignal(x: Double, y: Double = 0, confidence: Double = 0.9) -> HeadSignal {
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

func testPointerMotion() {
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
    expect(fastDelta > slowDelta * 2, "larger faster movement accelerates more than slow movement")

    let hysteresisHold = pointer.step(signal: makeSignal(x: 0.08), timestamp: 1.5, screens: [screen])!
    expect(hysteresisHold.x > slowEnd.x, "outer-to-inner hysteresis keeps movement active")
    let stopped = pointer.step(signal: makeSignal(x: 0.01), timestamp: 1.6, screens: [screen])!
    expectClose(stopped.x, hysteresisHold.x, tolerance: 0.5, "inner hysteresis band stops movement")

    pointer.requestRecenter()
    let recentered = pointer.step(signal: makeSignal(x: 0.35), timestamp: 1.7, screens: [screen])!
    expectClose(recentered.x, 250, tolerance: 0.5, "manual recenter centers pointer")
    let afterRecenter = pointer.step(signal: makeSignal(x: 0.35), timestamp: 1.8, screens: [screen])!
    expectClose(afterRecenter.x, recentered.x, tolerance: 0.5, "new neutral holds after recenter")

    var clamped = HeadPointerMotion(config: HeadPointerConfig(movementMode: .edge, speed: 10, distanceToEdge: 0.04))
    _ = clamped.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    let nearEdge = clamped.step(signal: makeSignal(x: 2), timestamp: 2, screens: [screen, CGRect(x: 800, y: 0, width: 500, height: 500)])!
    expect(containsInclusive(screen, nearEdge) || containsInclusive(CGRect(x: 800, y: 0, width: 500, height: 500), nearEdge), "integrated pointer clamps into a real screen")

    var relative = HeadPointerMotion(config: HeadPointerConfig(movementMode: .relative, speed: 5, distanceToEdge: 0.12))
    _ = relative.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    let relativeMove = relative.step(signal: makeSignal(x: 0.45), timestamp: 0.2, screens: [screen])!
    expect(relativeMove.x > 250, "relative mode moves from face translation")
}

func testPeriodicRecenterOnlyWhileStable() {
    let screen = CGRect(x: 0, y: 0, width: 500, height: 500)
    var stable = HeadPointerMotion(config: .default)
    _ = stable.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    for frame in 1...150 {
        _ = stable.step(signal: makeSignal(x: 0.04), timestamp: Double(frame) / 30, screens: [screen])
    }
    expect(
        (stable.neutralNoseOffsetXForSelfTest ?? 0) > 0,
        "stable in-band drift can slowly update neutral"
    )

    var active = HeadPointerMotion(config: .default)
    _ = active.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    for frame in 1...150 {
        _ = active.step(signal: makeSignal(x: 0.4), timestamp: Double(frame) / 30, screens: [screen])
    }
    expectClose(
        active.neutralNoseOffsetXForSelfTest ?? -1,
        0,
        tolerance: 0.0001,
        "active movement does not drag neutral"
    )
}

func testModelRecoversAfterNoFaceGap() {
    let screen = CGRect(x: 0, y: 0, width: 500, height: 500)
    var model = HeadTrackingModel()
    let initial = makeSignal(x: 0)
    let initialFace = FaceCandidate(id: "initial", boundingBox: initial.faceBox, confidence: 0.9)
    expect(model.chooseFace(from: [initialFace])?.id == "initial", "model selects initial face")
    expect(model.point(for: initial, timestamp: 0, screens: [screen]) != nil, "initial face produces a point")

    for _ in 0..<3 {
        expect(model.chooseFace(from: []) == nil, "missing face produces no candidate")
        model.missFace()
    }

    let returned = HeadSignal(
        makeSignal(x: 0.02),
        faceBox: CGRect(x: 0.78, y: 0.2, width: 0.18, height: 0.3),
        eyeDistance: 0.09
    )
    let returnedFace = FaceCandidate(id: "returned", boundingBox: returned.faceBox, confidence: 0.9)
    expect(model.chooseFace(from: [returnedFace])?.id == "returned", "model reacquires after a no-face gap")
    expect(model.point(for: returned, timestamp: 1, screens: [screen]) != nil, "freshly reacquired face is not rejected by stale geometry")
}

func testControlCommandParsing() {
    expect(parseControlCommand(#"{"kind":"recenter"}"#) == .recenter, "recenter command parses")
    let command = parseControlCommand(#"{"kind":"config","headPointer":{"movementMode":"relative","speed":7,"distanceToEdge":0.2}}"#)
    expect(command == .config(HeadPointerConfig(movementMode: .relative, speed: 7, distanceToEdge: 0.2)), "config command parses")
}

func testAbsolutePointerMode() {
    let screen = CGRect(x: 0, y: 0, width: 500, height: 500)
    var pointer = HeadPointerMotion(config: HeadPointerConfig(movementMode: .absolute, speed: 5, distanceToEdge: 0.12))
    var clock = 0.0
    func settle(_ signal: HeadSignal) -> CGPoint {
        var last = CGPoint.zero
        for _ in 0..<25 {
            last = pointer.step(signal: signal, timestamp: clock, screens: [screen])!
            clock += 0.033
        }
        return last
    }

    // First frame captures neutral; a neutral pose maps to screen center.
    let center = pointer.step(signal: makeSignal(x: 0, y: 0), timestamp: clock, screens: [screen])!
    clock += 0.033
    expectClose(center.x, 250, tolerance: 1, "absolute: neutral pose maps to center x")
    expectClose(center.y, 250, tolerance: 1, "absolute: neutral pose maps to center y")

    // Looking right moves the cursor right — and HOLDING the pose holds the cursor
    // (no velocity integration / drift, unlike rate control).
    let right = settle(makeSignal(x: 0.15, y: 0))
    expect(right.x > 260, "absolute: looking right moves the cursor right of center")
    let rightHold = pointer.step(signal: makeSignal(x: 0.15, y: 0), timestamp: clock, screens: [screen])!
    clock += 0.033
    expectClose(rightHold.x, right.x, tolerance: 1, "absolute: holding a pose holds the cursor (no drift)")

    // Looking UP reaches the upper half — the axis rate control could never reach —
    // and the vertical range is symmetric with looking down.
    let up = settle(makeSignal(x: 0, y: 0.15))
    expect(up.y > 260, "absolute: looking up reaches the upper half")
    let down = settle(makeSignal(x: 0, y: -0.15))
    expect(down.y < 240, "absolute: looking down reaches the lower half")
    expectClose(up.y - 250, 250 - down.y, tolerance: 5, "absolute: vertical range is symmetric")
}

func runSelfTest() {
    let primary = CGRect(x: 0, y: 0, width: 100, height: 100)
    let secondary = CGRect(x: 200, y: 0, width: 100, height: 100)
    let clamped = clampIntoRealScreen(CGPoint(x: 150, y: 50), screens: [primary, secondary])
    expect(containsInclusive(primary, clamped) || containsInclusive(secondary, clamped), "gap point clamps into a real screen")

    testActiveFaceSelection()
    testSignalExtractionAndFrameGate()
    testPointerMotion()
    testPeriodicRecenterOnlyWhileStable()
    testModelRecoversAfterNoFaceGap()
    testControlCommandParsing()
    testAbsolutePointerMode()

    expectEvent(startEvent(ts: 123), kind: "start", keys: ["kind", "ts"])
    expectEvent(stopEvent(ts: 123), kind: "stop", keys: ["kind", "ts"])
    expectEvent(errorEvent(message: "boom", ts: 123), kind: "error", keys: ["kind", "message", "ts"])

    let event = pointEvent(x: 1, y: 2, yaw: nil, pitch: 0.1, confidence: 2, ts: 123)
    expectEvent(event, kind: "point", keys: ["kind", "x", "y", "yaw", "pitch", "confidence", "ts"])
    expect(event["yaw"] is NSNull, "nil yaw serializes as null")
    expect(event["confidence"] as? Double == 1, "confidence is clamped to wire range")

    print("head-track selftest ok")
}
