import XCTest
import CoreGraphics
@testable import DirectorSidecar

/// S2·T6 — publish perception events onto the S1 bridge topics. The hand pointer becomes a
/// `cursorPosition` pointer, the face gaze a `gazeFocus` region, a final transcript a `transcript`
/// frame — all epoch-ms.
///
/// **N2 (no double-flip):** `PointerOutput.point` is ALREADY CG top-left (I7), so the cursor is
/// published with x/y UNCHANGED — the single cocoaToCG flip lives in Envelope and is applied ONLY
/// to a Cocoa-sourced gaze RECT, never re-applied to an already-top-left point. A golden assertion
/// pins that the published y equals the source y (a re-flip would make it screenHeight − y). I6:
/// a frozen face dims (low confidence, hold last good) but its region is centered on the held
/// point, never (0,0). (RESEARCH_CONVERGENCE §6/§7.)
final class PerceptionPublisherTests: XCTestCase {

    private let publisher = PerceptionPublisher()

    // MARK: cursor — N2 no double-flip

    func test_handPointer_publishesCursorPosition_userVirtualDesktopPx_noReflip() {
        // point is already CG top-left; on a 1080-tall desktop a re-flip would give 1080−880=200.
        let output = PointerOutput(point: CGPoint(x: 640, y: 880), state: .live, confidence: 0.9)
        let payload = publisher.cursorPosition(from: output, tsEpochMillis: 1_750_000_000_000)

        let pointer = try! XCTUnwrap(payload.pointers.first)
        XCTAssertEqual(pointer.x, 640)
        XCTAssertEqual(pointer.y, 880, "N2 — already top-left, published UNCHANGED (no re-flip to 200)")
        XCTAssertEqual(pointer.space, "virtual-desktop-px")
        XCTAssertEqual(pointer.kind, "user")
        XCTAssertEqual(pointer.state, "moving")
        XCTAssertEqual(pointer.confidence, 0.9)
        XCTAssertEqual(pointer.ts, 1_750_000_000_000)
    }

    func test_frozenHandPointer_publishesLockedState_heldPoint() {
        let output = PointerOutput(point: CGPoint(x: 300, y: 200), state: .frozen, confidence: nil)
        let pointer = try! XCTUnwrap(publisher.cursorPosition(from: output).pointers.first)
        XCTAssertEqual(pointer.state, "locked", "frozen → locked (held)")
        XCTAssertEqual(pointer.x, 300)
        XCTAssertEqual(pointer.y, 200)
    }

    // MARK: gaze — face point (no flip) vs Cocoa rect (the one flip)

    func test_facePointer_publishesGazeFocus_regionCenteredOnTopLeftPoint_noFlip() {
        let output = PointerOutput(point: CGPoint(x: 500, y: 400), state: .live, confidence: 0.7)
        let gaze = publisher.gazeFocus(from: output, size: CGSize(width: 200, height: 100))
        // region centered on the point, NOT flipped.
        XCTAssertEqual(gaze.bounds.x, 400) // 500 − 200/2
        XCTAssertEqual(gaze.bounds.y, 350) // 400 − 100/2
        XCTAssertEqual(gaze.bounds.w, 200)
        XCTAssertEqual(gaze.bounds.h, 100)
        XCTAssertEqual(gaze.confidence, 0.7)
    }

    func test_frozenFace_dims_butRegionNeverZeroZero() {
        let held = PointerOutput(point: CGPoint(x: 512, y: 384), state: .frozen, confidence: nil)
        let gaze = publisher.gazeFocus(from: held, size: CGSize(width: 200, height: 100))
        XCTAssertEqual(gaze.confidence, PerceptionPublisher.frozenDimConfidence, "frozen face dims")
        XCTAssertLessThan(gaze.confidence, 0.7, "dim is below a live confidence")
        XCTAssertNotEqual(gaze.bounds.x, 0, "region centered on the held point, never (0,0)")
        XCTAssertEqual(gaze.bounds.x, 412) // 512 − 100
        XCTAssertEqual(gaze.bounds.y, 334) // 384 − 50
    }

    func test_cocoaGazeRect_isFlippedThroughEnvelopeCocoaToCG() {
        // A Cocoa (bottom-left, y-up) rect: this IS the one path that flips. cocoaToCG of the
        // bottom edge y=200, height 150, on a 1080 desktop → 1080 − (200+150) = 730.
        let gaze = publisher.gazeFocus(
            fromCocoaRect: CGRect(x: 100, y: 200, width: 300, height: 150),
            screenHeight: 1080, confidence: 0.6)
        XCTAssertEqual(gaze.bounds.x, 100)
        XCTAssertEqual(gaze.bounds.y, 730, "Cocoa rect top edge flipped via Envelope cocoaToCG")
        XCTAssertEqual(gaze.bounds.w, 300)
        XCTAssertEqual(gaze.bounds.h, 150)
    }

    // (transcript path intentionally not ported — DirectorSidecar's SpeechService owns transcripts,
    // not the perception publisher; the source's transcript test is dropped here.)
}
