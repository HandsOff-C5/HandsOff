//
//  GestureLoopTests.swift
//  DirectorSidecarTests
//
//  Port of packages/gesture/src/state-machine/machine.test.ts + runtime/referent-loop.test.ts
//  + mediapipe/detector.test.ts.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - machine.test.ts

private let candidate = Contracts.PointingCandidate(targetId: "win-1", confidence: 0.9, calibrationQuality: .good)

private func runMachine(_ steps: [(GestureEvent, GestureGuards)]) -> (state: GestureMachineState, phases: [Contracts.GestureState]) {
    var state = GestureMachine.initialState()
    var phases: [Contracts.GestureState] = []
    for (event, guards) in steps {
        state = GestureMachine.reduce(state, event, guards).state
        phases.append(state.phase)
    }
    return (state, phases)
}

@Test func machineStartsIdle() {
    #expect(GestureMachine.initialState().phase == .idle)
}

@Test func machinePointFromIdleToCandidate() {
    let r = GestureMachine.reduce(GestureMachine.initialState(), .point(candidate: candidate))
    #expect(r.state.phase == .candidate)
    #expect(r.state.candidate == candidate)
    #expect(r.emit == nil)
}

@Test func machineHoldWithDwellLocksAndEmitsOnce() {
    let candidateState = GestureMachine.reduce(GestureMachine.initialState(), .point(candidate: candidate)).state
    let first = GestureMachine.reduce(candidateState, .hold(timestampMs: 1000), GestureGuards(dwellSatisfied: true))
    #expect(first.state.phase == .locked)
    #expect(first.emit == .locked(Contracts.LockedReferent(targetId: "win-1", confidence: 0.9, lockedAtMs: 1000)))

    let second = GestureMachine.reduce(first.state, .hold(timestampMs: 1100), GestureGuards(dwellSatisfied: true))
    #expect(second.state.phase == .locked)
    #expect(second.emit == nil)
}

@Test func machineHoldWithoutDwellStaysCandidate() {
    let s = GestureMachine.reduce(GestureMachine.initialState(), .point(candidate: candidate)).state
    let r = GestureMachine.reduce(s, .hold(timestampMs: 1000), GestureGuards(dwellSatisfied: false))
    #expect(r.state.phase == .candidate)
    #expect(r.emit == nil)
}

@Test func machineCancelFromCandidateToIdle() {
    let s = GestureMachine.reduce(GestureMachine.initialState(), .point(candidate: candidate)).state
    let r = GestureMachine.reduce(s, .cancel)
    #expect(r.state.phase == .idle)
    #expect(r.emit == .interrupt(Contracts.InterruptIntent(kind: .cancel)))
    #expect(r.state.candidate == nil)
}

@Test func machineCancelFromLockedToIdle() {
    var s = GestureMachine.reduce(GestureMachine.initialState(), .point(candidate: candidate)).state
    s = GestureMachine.reduce(s, .hold(timestampMs: 1), GestureGuards(dwellSatisfied: true)).state
    let r = GestureMachine.reduce(s, .cancel)
    #expect(r.state.phase == .idle)
    #expect(r.emit == .interrupt(Contracts.InterruptIntent(kind: .cancel)))
}

@Test func machinePauseAndStopToInterrupt() {
    var s = GestureMachine.reduce(GestureMachine.initialState(), .point(candidate: candidate)).state
    s = GestureMachine.reduce(s, .hold(timestampMs: 1), GestureGuards(dwellSatisfied: true)).state

    let paused = GestureMachine.reduce(s, .pause)
    #expect(paused.state.phase == .interrupt)
    #expect(paused.emit == .interrupt(Contracts.InterruptIntent(kind: .pause)))

    let stopped = GestureMachine.reduce(s, .stop)
    #expect(stopped.state.phase == .interrupt)
    #expect(stopped.emit == .interrupt(Contracts.InterruptIntent(kind: .stop)))
}

@Test func machineLostFromCandidateToIdle() {
    let s = GestureMachine.reduce(GestureMachine.initialState(), .point(candidate: candidate)).state
    let r = GestureMachine.reduce(s, .lost)
    #expect(r.state.phase == .idle)
    #expect(r.emit == nil)
    #expect(r.state.candidate == nil)
}

@Test func machineNoisySequenceNeverLocks() {
    let (state, phases) = runMachine([
        (.point(candidate: candidate), GestureGuards()),
        (.hold(timestampMs: 10), GestureGuards(dwellSatisfied: false)),
        (.hold(timestampMs: 20), GestureGuards(dwellSatisfied: false)),
        (.hold(timestampMs: 30), GestureGuards(dwellSatisfied: false)),
        (.lost, GestureGuards()),
    ])
    #expect(!phases.contains(.locked))
    #expect(state.phase == .idle)
}

// MARK: - referent-loop.test.ts

private let IDENTITY = CalibrationAffine(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0)
private let loopSurfaces: [Contracts.Surface] = [
    Contracts.Surface(id: "win-1", bounds: Contracts.SurfaceBounds(x: 0, y: 0, w: 1, h: 1), displayId: "d0"),
]
private let loopDwell = DwellDebounceParams(enter: 0.6, exit: 0.4, dwellMs: 200, cooldownMs: 1000)

private func handAt(_ x: Double, _ y: Double, _ score: Double) throws -> Contracts.Hand {
    var lm = Array(repeating: Contracts.Landmark(x: 0, y: 0, z: 0, visibility: 1), count: 21)
    lm[8] = Contracts.Landmark(x: x, y: y, z: 0, visibility: 1)
    return try Contracts.Hand(landmarks: lm, handedness: .right, score: score)
}

private func loopFrame(_ hand: Contracts.Hand?, _ timestampMs: Double = 0) -> Contracts.LandmarkFrame {
    Contracts.LandmarkFrame(timestampMs: timestampMs, hands: hand.map { [$0] } ?? [])
}

private func makeLoop(_ surfaces: [Contracts.Surface] = loopSurfaces) -> ReferentLoop {
    ReferentLoop(ReferentLoopOptions(transform: IDENTITY, surfaces: surfaces, calibrationQuality: .good, dwell: loopDwell))
}

@Test func loopStaysIdleForNoHand() throws {
    let out = try makeLoop().process(loopFrame(nil), 50)
    #expect(out.state.phase == .idle)
    #expect(out.candidate == nil)
    #expect(out.active == false)
}

@Test func loopSmoothsConfidenceAcrossFrames() throws {
    let out = try makeLoop().process(loopFrame(try handAt(0.5, 0.5, 0.95)), 50)
    #expect(out.confidence > 0)
    #expect(out.confidence < 0.95)
    #expect(out.active == false)
}

@Test func loopOneEuroSmoothedPointAttenuatesSpike() throws {
    let l = makeLoop()
    let steady = try handAt(0.5, 0.5, 0.95)
    var out = try l.process(loopFrame(steady, 0), 50)
    for i in 1..<5 { out = try l.process(loopFrame(steady, Double(i) * 50), 50) }
    #expect(gClose(out.point.x, 0.5, 2))
    #expect(gClose(out.point.y, 0.5, 2))
    out = try l.process(loopFrame(try handAt(0.9, 0.1, 0.95), 250), 50)
    #expect(out.point.x > 0.5 && out.point.x < 0.9)
    #expect(out.point.y < 0.5 && out.point.y > 0.1)
}

@Test func loopReliabilityDropsWhenOccluded() throws {
    let l = makeLoop()
    let clear = try l.process(loopFrame(try handAt(0.5, 0.5, 0.9)), 50)
    #expect(gClose(clear.reliability, 0.9))

    var lm = try handAt(0.5, 0.5, 0.9).landmarks
    lm[8] = Contracts.Landmark(x: lm[8].x, y: lm[8].y, z: lm[8].z, visibility: 0.2)
    let occluded = try Contracts.Hand(landmarks: lm, handedness: .right, score: 0.9)
    #expect(gClose(try l.process(loopFrame(occluded, 50), 50).reliability, 0.18))
}

@Test func loopReliabilityZeroWithNoHand() throws {
    #expect(try makeLoop().process(loopFrame(nil), 50).reliability == 0)
}

@Test func loopEngagesAfterSteadyPointing() throws {
    let l = makeLoop()
    let hand = try handAt(0.5, 0.5, 0.95)
    var out = try l.process(loopFrame(hand, 50), 50)
    for i in 1..<4 { out = try l.process(loopFrame(hand, 50 + Double(i) * 50), 50) }
    #expect(out.candidate?.targetId == "win-1")
    #expect(out.active == true)
    #expect(out.state.phase != .idle)
}

@Test func loopLocksOnceOnDwell() throws {
    let l = makeLoop()
    let hand = try handAt(0.5, 0.5, 0.95)
    #expect(try l.process(loopFrame(hand, 0), 50).state.phase != .locked)
    var emits = 0
    var lockedAt = -1
    for i in 1...30 {
        let out = try l.process(loopFrame(hand, Double(i) * 50), 50)
        if case .locked = out.emit {
            emits += 1
            if lockedAt < 0 { lockedAt = i }
        }
    }
    #expect(lockedAt > 0)
    #expect(emits == 1)
}

@Test func loopNeverLocksBelowEnterThreshold() throws {
    let l = makeLoop()
    let jittery = try handAt(0.5, 0.5, 0.3)
    var t = 0.0
    while t < 2000 {
        let out = try l.process(loopFrame(jittery, t), 50)
        #expect(out.state.phase != .locked)
        #expect(out.active == false)
        t += 50
    }
}

@Test func loopDoesNotLockWhileTargetChanges() throws {
    let split: [Contracts.Surface] = [
        Contracts.Surface(id: "left", bounds: Contracts.SurfaceBounds(x: 0, y: 0, w: 0.5, h: 1), displayId: "d0"),
        Contracts.Surface(id: "right", bounds: Contracts.SurfaceBounds(x: 0.5, y: 0, w: 0.5, h: 1), displayId: "d0"),
    ]
    let l = makeLoop(split)
    for i in 0..<40 {
        let x = i % 2 == 0 ? 0.25 : 0.75
        #expect(try l.process(loopFrame(try handAt(x, 0.5, 0.95), Double(i) * 50), 50).state.phase != .locked)
    }
}

@Test func loopKeepsLockedWhenHandDisappears() throws {
    let l = makeLoop()
    let hand = try handAt(0.5, 0.5, 0.95)
    for i in 1...30 { _ = try l.process(loopFrame(hand, Double(i) * 50), 50) }
    #expect(try l.process(loopFrame(nil, 1600), 50).state.phase == .locked)
}

@Test func loopPointFixtureLocks() throws {
    let frames = try GestureFixtures.decode([Contracts.LandmarkFrame].self, "point.golden.json")
    let l = makeLoop()
    var phase = Contracts.GestureState.idle
    for f in frames { phase = try l.process(f, 250).state.phase }
    #expect(phase == .locked)
}

@Test func loopLowConfidenceFixtureNeverLocks() throws {
    let frames = try GestureFixtures.decode([Contracts.LandmarkFrame].self, "low-confidence.golden.json")
    let l = makeLoop()
    for f in frames { #expect(try l.process(f, 250).state.phase != .locked) }
}

// MARK: - detector.test.ts

private final class FakeDetector: LandmarkDetector {
    private let result: LandmarkParsing.RawHandLandmarkerResult?
    private let error: Error?
    private(set) var calls = 0

    init(result: LandmarkParsing.RawHandLandmarkerResult) { self.result = result; self.error = nil }
    init(error: Error) { self.result = nil; self.error = error }

    func detectForVideo(_ source: TimedFrameSource, _ timestampMs: Double) throws -> LandmarkParsing.RawHandLandmarkerResult {
        calls += 1
        if let error { throw error }
        return result!
    }
}

private func rawOneHand() -> LandmarkParsing.RawHandLandmarkerResult {
    LandmarkParsing.RawHandLandmarkerResult(
        landmarks: [(0..<21).map { LandmarkParsing.RawLandmark(x: Double($0) / 21, y: Double($0) / 21, z: 0, visibility: nil) }],
        handednesses: [[LandmarkParsing.RawCategory(categoryName: "Right", score: 0.9)]]
    )
}

@Test func processorParsesChangedFrameAndReports() {
    var resultCount = 0
    var last: DetectionResult?
    let processor = LandmarkProcessor(detector: FakeDetector(result: rawOneHand()), onResult: { resultCount += 1; last = $0 })
    let out = processor.process(TimedFrameSource(currentTime: 0.1), 1000)
    #expect(out?.frame.hands.count == 1)
    #expect(out?.frame.hands[0].handedness == .right)
    #expect(resultCount == 1)
    #expect(last != nil)
}

@Test func processorSkipsUnchangedFrame() {
    let detector = FakeDetector(result: rawOneHand())
    let processor = LandmarkProcessor(detector: detector)
    _ = processor.process(TimedFrameSource(currentTime: 0.1), 1000)
    let second = processor.process(TimedFrameSource(currentTime: 0.1), 1016)
    #expect(second == nil)
    #expect(detector.calls == 1)
}

@Test func processorComputesFps() {
    let processor = LandmarkProcessor(detector: FakeDetector(result: rawOneHand()))
    let first = processor.process(TimedFrameSource(currentTime: 0.1), 1000)
    let second = processor.process(TimedFrameSource(currentTime: 0.2), 1100)
    #expect(first?.fps == 0)
    #expect(gClose(second?.fps ?? -1, 10))
}

@Test func processorCatchesDetectorError() {
    var errorCount = 0
    let processor = LandmarkProcessor(
        detector: FakeDetector(error: HandLandmarkerError.runtime("WebGL context lost")),
        onError: { _ in errorCount += 1 }
    )
    #expect(processor.process(TimedFrameSource(currentTime: 0.1), 1000) == nil)
    #expect(processor.process(TimedFrameSource(currentTime: 0.2), 1016) == nil)
    #expect(errorCount == 2)
}

@Test func processorCatchesParseError() {
    var errorCount = 0
    let malformed = LandmarkParsing.RawHandLandmarkerResult(
        landmarks: [[LandmarkParsing.RawLandmark(x: 0, y: 0, z: 0, visibility: nil)]],
        handednesses: [[LandmarkParsing.RawCategory(categoryName: "Right", score: 0.9)]]
    )
    let processor = LandmarkProcessor(detector: FakeDetector(result: malformed), onError: { _ in errorCount += 1 })
    #expect(processor.process(TimedFrameSource(currentTime: 0.1), 1000) == nil)
    #expect(errorCount == 1)
}
