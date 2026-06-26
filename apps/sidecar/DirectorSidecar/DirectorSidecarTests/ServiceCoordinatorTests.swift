//
//  ServiceCoordinatorTests.swift
//  DirectorSidecarTests
//
//  Track F (ADR 0005). Verifies the service-lifecycle coordinator WITHOUT a real camera/mic — a
//  front-camera AVCaptureSession and AVAudioEngine can't run under headless `xcodebuild`, so the
//  head/speech services are injected as fakes through the `HeadSensing`/`SpeechStreaming` seams.
//  The pure head-point→cursor projection is tested directly. The live sensor→cursor path needs the
//  bundled .app (see PORTING.md note on Track F) and can't be proven here.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Fakes

@MainActor
private final class FakeHead: HeadSensing {
    nonisolated let events: AsyncStream<HeadPointerEvent>
    nonisolated let continuation: AsyncStream<HeadPointerEvent>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var finishCount = 0

    init() { (events, continuation) = AsyncStream.makeStream() }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func finish() { finishCount += 1; continuation.finish() }
}

@MainActor
private final class FakeSpeech: SpeechStreaming {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var continuation: AsyncStream<SpeechService.Event>.Continuation?

    func start() -> AsyncStream<SpeechService.Event> {
        startCount += 1
        return AsyncStream { self.continuation = $0 }
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func emit(_ event: SpeechService.Event) { continuation?.yield(event) }
}

@MainActor
private final class FakeHand: HandSensing {
    nonisolated let events: AsyncStream<DetectionResult>
    nonisolated let continuation: AsyncStream<DetectionResult>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var finishCount = 0

    init() { (events, continuation) = AsyncStream.makeStream() }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func finish() { finishCount += 1; continuation.finish() }
}

/// A live hand frame whose index fingertip (landmark 8) sits at (x, y); the rest are filler so the
/// 21-landmark contract holds. The default wrist→tip signal is just the tip.
private func handDetection(_ x: Double, _ y: Double, _ score: Double, ts: Double) throws -> DetectionResult {
    var lm = Array(repeating: Contracts.Landmark(x: 0, y: 0, z: 0, visibility: 1), count: 21)
    lm[8] = Contracts.Landmark(x: x, y: y, z: 0, visibility: 1)
    let hand = try Contracts.Hand(landmarks: lm, handedness: .right, score: score)
    return DetectionResult(frame: Contracts.LandmarkFrame(timestampMs: ts, hands: [hand]), fps: 0)
}

/// A gesture `ReferentLoop` with an identity calibration and one surface covering the whole space —
/// so any pointing hand lands on it (the test injects this where the app injects a screen-spanning one).
@MainActor
private func makeGestureLoop() -> ReferentLoop {
    ReferentLoop(ReferentLoopOptions(
        transform: CalibrationAffine(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0),
        surfaces: [Contracts.Surface(id: "win-1", bounds: Contracts.SurfaceBounds(x: 0, y: 0, w: 1, h: 1), displayId: "d0")],
        calibrationQuality: .good,
        dwell: DwellDebounceParams(enter: 0.6, exit: 0.4, dwellMs: 200, cooldownMs: 1000)))
}

// MARK: - Pure projection

@Test func gestureProjectionMapsLoopResultOntoTheUserCursorTopic() {
    let result = ReferentLoopResult(
        state: GestureMachine.initialState(), candidate: nil, confidence: 0, active: false,
        point: Vec2(100.5, 200.25), reliability: 0.8, emit: nil)
    let pointer = GestureReferentBridge.pointer(from: result, ts: 4242)

    #expect(pointer.x == 100.5)
    #expect(pointer.y == 200.25)
    #expect(pointer.space == "virtual-desktop-px")
    #expect(pointer.kind == "user")
    #expect(pointer.id == "user")          // shares the head's `.user` reticle
    #expect(pointer.state == "moving")
    #expect(pointer.confidence == 0.8)     // the hand-channel fusion weight
    #expect(pointer.ts == 4242)
}

@Test func projectionMapsHeadPointOntoTheUserCursorTopic() {
    // Confidence 1.4 is clamped to 1.0 at HeadPoint construction (the wire clamped at encode time).
    let head = HeadPoint(x: 100.5, y: 200.25, yaw: 0.1, pitch: -0.2, confidence: 1.4, ts: 1717)
    let pointer = HeadPointerBridge.pointer(from: head)

    #expect(pointer.x == 100.5)            // contract space passes straight through — no re-flip
    #expect(pointer.y == 200.25)
    #expect(pointer.space == "virtual-desktop-px")
    #expect(pointer.kind == "user")
    #expect(pointer.agentId == nil)
    #expect(pointer.id == "user")          // Pointer.id == agentId ?? kind → matches OverlayModel.userId
    #expect(pointer.state == "moving")     // a live head point = actively pointing
    #expect(pointer.confidence == 1.0)
    #expect(pointer.ts == 1717)
}

// MARK: - Lifecycle

@MainActor
@Test func setSensingBringsBothSensorsUpAndDownAndIsIdempotent() {
    let head = FakeHead()
    let speech = FakeSpeech()
    let coordinator = ServiceCoordinator(head: head, speech: speech, onHeadPointer: { _ in })

    #expect(!coordinator.isSensing)

    coordinator.setSensing(true)
    #expect(coordinator.isSensing)
    #expect(head.startCount == 1)
    #expect(speech.startCount == 1)

    coordinator.setSensing(true)           // same state → no double-start (no second permission prompt)
    #expect(head.startCount == 1)
    #expect(speech.startCount == 1)

    coordinator.setSensing(false)
    #expect(!coordinator.isSensing)
    #expect(head.stopCount == 1)
    #expect(speech.stopCount == 1)

    coordinator.setSensing(false)          // idempotent off
    #expect(head.stopCount == 1)
    #expect(speech.stopCount == 1)
}

@MainActor
@Test func headPointsFlowToTheCursorCallbackWhileConsuming() async {
    let head = FakeHead()
    let speech = FakeSpeech()
    let delivered = AsyncStream<Pointer>.makeStream()
    let coordinator = ServiceCoordinator(
        head: head, speech: speech,
        onHeadPointer: { delivered.continuation.yield($0) }
    )

    coordinator.start()          // wires the head-event consumer
    coordinator.setSensing(true) // camera "on"

    head.continuation.yield(.point(HeadPoint(x: 12, y: 34, yaw: nil, pitch: nil, confidence: 0.9, ts: 1000)))

    var iterator = delivered.stream.makeAsyncIterator()
    let pointer = await iterator.next()
    #expect(pointer?.x == 12)
    #expect(pointer?.y == 34)
    #expect(pointer?.kind == "user")
    #expect(pointer?.confidence == 0.9)
}

@MainActor
@Test func headPointsAlsoFlowToTheRawHeadPointSink() async {
    // The intent path (HeadPointSnapshot ← onHeadPoint) consumes the RAW HeadPoint off the same
    // `.point` feed that drives the cursor — so a look reaches the loop, not just the overlay.
    let head = FakeHead()
    let speech = FakeSpeech()
    let delivered = AsyncStream<HeadPoint>.makeStream()
    let coordinator = ServiceCoordinator(
        head: head, speech: speech,
        onHeadPointer: { _ in },
        onHeadPoint: { delivered.continuation.yield($0) }
    )

    coordinator.start()
    coordinator.setSensing(true)

    let point = HeadPoint(x: 150, y: 250, yaw: 0.1, pitch: -0.2, confidence: 0.8, ts: 99)
    head.continuation.yield(.point(point))

    var iterator = delivered.stream.makeAsyncIterator()
    let received = await iterator.next()
    #expect(received == point)   // the raw head point (yaw/pitch/confidence intact), not a projected cursor
}

@MainActor
@Test func nonPointEventsDoNotEmitACursor() async {
    let head = FakeHead()
    let speech = FakeSpeech()
    let delivered = AsyncStream<Pointer>.makeStream()
    let coordinator = ServiceCoordinator(
        head: head, speech: speech,
        onHeadPointer: { delivered.continuation.yield($0) }
    )
    coordinator.start()
    coordinator.setSensing(true)

    // started/error are lifecycle noise for the cursor path; only a following .point should arrive.
    head.continuation.yield(.started(ts: 1))
    head.continuation.yield(.error(message: "camera blip", ts: 2))
    head.continuation.yield(.point(HeadPoint(x: 5, y: 6, yaw: nil, pitch: nil, confidence: 1, ts: 3)))

    var iterator = delivered.stream.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.x == 5)       // the started/error events were skipped, not projected
    #expect(first?.y == 6)
}

@MainActor
@Test func teardownStopsSensingFinishesStreamAndIsInertAfterward() {
    let head = FakeHead()
    let speech = FakeSpeech()
    let coordinator = ServiceCoordinator(head: head, speech: speech, onHeadPointer: { _ in })

    coordinator.start()
    coordinator.setSensing(true)
    coordinator.teardown()

    #expect(coordinator.isTornDown)
    #expect(!coordinator.isSensing)
    #expect(head.stopCount == 1)     // sensing was up → stopped on teardown
    #expect(speech.stopCount == 1)
    #expect(head.finishCount == 1)   // head event stream finished

    // Inert after teardown: no resurrecting the camera on a late notification.
    coordinator.setSensing(true)
    #expect(!coordinator.isSensing)
    #expect(head.startCount == 1)    // unchanged from the pre-teardown start

    coordinator.teardown()           // idempotent
    #expect(head.finishCount == 1)
}

@MainActor
@Test func teardownWithoutSensingStillFinishesTheStream() {
    let head = FakeHead()
    let speech = FakeSpeech()
    let coordinator = ServiceCoordinator(head: head, speech: speech, onHeadPointer: { _ in })

    coordinator.start()
    coordinator.teardown()           // never sensed

    #expect(coordinator.isTornDown)
    #expect(head.stopCount == 0)     // sensing was never on
    #expect(speech.stopCount == 0)
    #expect(head.finishCount == 1)   // but the stream is still finished cleanly
}

// MARK: - Hand-gesture lane lifecycle

@MainActor
@Test func setSensingBringsTheHandSensorUpAndDown() {
    let head = FakeHead()
    let speech = FakeSpeech()
    let hand = FakeHand()
    let coordinator = ServiceCoordinator(
        head: head, speech: speech, hand: hand, loop: makeGestureLoop(), onHeadPointer: { _ in })

    coordinator.setSensing(true)
    #expect(hand.startCount == 1)
    coordinator.setSensing(true)     // idempotent
    #expect(hand.startCount == 1)
    coordinator.setSensing(false)
    #expect(hand.stopCount == 1)
}

@MainActor
@Test func handFrameDrivesTheCursorAndRecordsAReferent() async throws {
    let head = FakeHead()
    let speech = FakeSpeech()
    let hand = FakeHand()
    let cursors = AsyncStream<Pointer>.makeStream()
    let referents = AsyncStream<GestureReferent>.makeStream()
    let coordinator = ServiceCoordinator(
        head: head, speech: speech, hand: hand, loop: makeGestureLoop(),
        onHeadPointer: { _ in },
        onGesturePointer: { cursors.continuation.yield($0) },
        onGestureReferent: { referents.continuation.yield($0) })

    coordinator.start()           // wires the hand-frame consumer
    coordinator.setSensing(true)  // camera "on"

    // A pointing hand at the center → identity calibration → cursor at (0.5, 0.5), positive reliability.
    hand.continuation.yield(try handDetection(0.5, 0.5, 0.95, ts: 0))

    var cursorIter = cursors.stream.makeAsyncIterator()
    let pointer = await cursorIter.next()
    #expect(pointer?.kind == "user")          // the hand drives the SAME `.user` cursor as the head
    #expect(pointer?.x == 0.5)                 // first 1€ sample passes through unchanged
    #expect(pointer?.y == 0.5)
    #expect((pointer?.confidence ?? 0) > 0)    // reliability = score × visibility

    var refIter = referents.stream.makeAsyncIterator()
    let referent = await refIter.next()
    #expect(referent?.cursor != nil)           // a hand present → a wrist-ray cursor for the intent
}

@MainActor
@Test func teardownAlsoStopsAndFinishesTheHand() {
    let head = FakeHead()
    let speech = FakeSpeech()
    let hand = FakeHand()
    let coordinator = ServiceCoordinator(
        head: head, speech: speech, hand: hand, loop: makeGestureLoop(), onHeadPointer: { _ in })

    coordinator.start()
    coordinator.setSensing(true)
    coordinator.teardown()

    #expect(hand.stopCount == 1)
    #expect(hand.finishCount == 1)
}
