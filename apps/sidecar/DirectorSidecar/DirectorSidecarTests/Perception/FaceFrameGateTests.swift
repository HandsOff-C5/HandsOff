import Testing
import CoreGraphics
@testable import DirectorSidecar

// Confidence floor + frame gate (FR-12 / FR-5 / I6). Frames below face.minConfidence are
// treated as lost: the pointer FREEZES and holds the last good point — it NEVER snaps to
// (0,0). The gate reuses the existing FreezeTracker<T> contract (Capture/FreezeTracker.swift):
// up to and including capture.lostFrameLimit consecutive losses stay .live (still holding),
// then it declares .frozen.

@Test func testBelowMinConfidenceEmitsFrozen() {
    var gate = FaceFrameGate()
    let good = FaceSignal(
        nose: CGPoint(x: 320, y: 250),
        leftEye: CGPoint(x: 300, y: 200),
        rightEye: CGPoint(x: 360, y: 200),
        confidence: 0.9
    )
    // Seed a good frame so there is a last-good point to hold.
    let live = gate.accept(good, heldPoint: CGPoint(x: 742, y: 318))
    #expect(live.state == .live)
    #expect(live.point == CGPoint(x: 742, y: 318))

    // Below face.minConfidence (0.45) → rejected; once losses EXCEED lostFrameLimit, frozen.
    let low = FaceSignal(
        nose: CGPoint(x: 320, y: 250),
        leftEye: CGPoint(x: 300, y: 200),
        rightEye: CGPoint(x: 360, y: 200),
        confidence: 0.30
    )
    var last = live
    for _ in 0...(Params.capture.lostFrameLimit) {  // lostFrameLimit+1 losses → exceeds
        last = gate.accept(low, heldPoint: CGPoint(x: 742, y: 318))
    }
    #expect(last.state == .frozen)
    // Holds last good — never (0,0).
    #expect(last.point == CGPoint(x: 742, y: 318))
    #expect(last.point != CGPoint(x: 0, y: 0))
}

@Test func testLostFrameLimitDeclaresLoss() {
    var gate = FaceFrameGate()
    let good = FaceSignal(
        nose: CGPoint(x: 320, y: 250),
        leftEye: CGPoint(x: 300, y: 200),
        rightEye: CGPoint(x: 360, y: 200),
        confidence: 0.9
    )
    let held = CGPoint(x: 100, y: 200)
    _ = gate.accept(good, heldPoint: held)

    let low = FaceSignal(
        nose: CGPoint(x: 320, y: 250),
        leftEye: CGPoint(x: 300, y: 200),
        rightEye: CGPoint(x: 360, y: 200),
        confidence: 0.0
    )

    // Up to and including lostFrameLimit losses: still .live (holding), never (0,0).
    for _ in 1...Params.capture.lostFrameLimit {
        let out = gate.accept(low, heldPoint: held)
        #expect(out.state == .live)
        #expect(out.point == held)
        #expect(out.point != .zero)
    }
    // One more loss EXCEEDS the limit → .frozen, still holding (never (0,0)).
    let frozen = gate.accept(low, heldPoint: held)
    #expect(frozen.state == .frozen)
    #expect(frozen.point == held)
    #expect(frozen.point != .zero)
}
