import XCTest
@testable import DirectorSidecar

/// S2·T1 — the perception emission seam. Each plugin's existing `step(…)→PointerOutput` is
/// wrapped into an Envelope `PointingEvent{header(source:.hand_pose/.face_gaze, conf, taint:.trusted),
/// screenHit, nBestTargets}` so the concurrent bus + aligner consume one shared event shape.
/// CLAUDE I6: a frozen (dropout) frame HOLDS the last good point — never (0,0) — and carries no
/// fresh referent and no confidence (I10 honesty). CLAUDE I7: `PointerOutput.point` is already CG
/// top-left, so the adapter copies it into `screenHit` unchanged (no flip here — N2). tSrc comes
/// from the one Envelope `MonotonicClock`. (RESEARCH_CONVERGENCE §7; MIGRATION §8.)
final class PointingEventAdapterTests: XCTestCase {

    private let adapter = PointingEventAdapter()

    func test_liveHand_carriesSourceConfTaintTrustedAndScreenHit() {
        let output = PointerOutput(point: CGPoint(x: 640, y: 360), state: .live, confidence: 0.82)
        let targets = [WindowOrRegionRef(id: "com.safari", conf: 0.9)]
        let event = adapter.event(from: output, source: .hand_pose, hand: .right, nBestTargets: targets)

        XCTAssertEqual(event.header.source, .hand_pose)
        XCTAssertEqual(event.header.taint, .trusted, "on-device perception is trusted provenance")
        XCTAssertEqual(event.header.conf, 0.82, accuracy: 1e-9)
        XCTAssertEqual(event.screenHit, PixelPoint(x: 640, y: 360), "screenHit copies the CG top-left point unchanged (no flip)")
        XCTAssertEqual(event.nBestTargets, targets)
        XCTAssertEqual(event.header.nBest, 1)
        XCTAssertEqual(event.hand, .right)
    }

    func test_faceSource_tagsFaceGaze() {
        let output = PointerOutput(point: CGPoint(x: 100, y: 200), state: .live, confidence: 0.5)
        let event = adapter.event(from: output, source: .face_gaze)
        XCTAssertEqual(event.header.source, .face_gaze)
        XCTAssertEqual(event.screenHit, PixelPoint(x: 100, y: 200))
    }

    func test_frozen_holdsLastGoodPoint_neverZeroZero_noFreshReferentNoConfidence() {
        // The plugin freezes on dropout and HOLDS the last good point (never origin) — the adapter
        // must preserve that held point, drop fresh referents, and report zero confidence.
        let held = CGPoint(x: 512, y: 384)
        let output = PointerOutput(point: held, state: .frozen, confidence: nil)
        let event = adapter.event(from: output, source: .hand_pose,
                                  nBestTargets: [WindowOrRegionRef(id: "stale", conf: 0.4)])

        XCTAssertEqual(event.screenHit, PixelPoint(x: 512, y: 384), "frozen → held last-good point")
        XCTAssertNotEqual(event.screenHit, PixelPoint(x: 0, y: 0), "I6 — never (0,0)")
        XCTAssertTrue(event.nBestTargets.isEmpty, "frozen frame yields no fresh referent")
        XCTAssertEqual(event.header.nBest, 0)
        XCTAssertEqual(event.header.conf, 0, "a held frame carries no confidence (I10)")
    }

    func test_tSrc_isMonotonicAcrossSuccessiveEvents() {
        let o = PointerOutput(point: CGPoint(x: 1, y: 1), state: .live, confidence: 0.5)
        let a = adapter.event(from: o, source: .hand_pose)
        let b = adapter.event(from: o, source: .hand_pose)
        XCTAssertLessThanOrEqual(a.header.tSrc, b.header.tSrc, "tSrc comes from the one monotonic clock")
    }
}
