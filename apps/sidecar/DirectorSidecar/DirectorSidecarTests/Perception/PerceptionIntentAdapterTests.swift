import Testing
import CoreGraphics
@testable import DirectorSidecar

/// Coverage for the two narrow seams the migration adds between the ported perception plugins'
/// `PointerOutput` and DirectorSidecar's intent evidence: `FaceIntentAdapter` (→ `HeadPoint`, the
/// `HeadPointSnapshot` the loop's `HeadPointingIntake` reads) and `HandIntentAdapter`
/// (→ `GestureReferent`, the `GestureSnapshot`). Both drop FROZEN frames so a dropout never
/// overwrites the last good evidence (I6: hold last good).
struct PerceptionIntentAdapterTests {

    // MARK: FaceIntentAdapter → HeadPoint

    @Test func liveFaceOutputBecomesHeadPoint() {
        let output = PointerOutput(point: CGPoint(x: 640, y: 360), state: .live, confidence: 0.8)
        let head = FaceIntentAdapter.headPoint(from: output, ts: 1_750_000_000_000)
        #expect(head != nil)
        #expect(head?.x == 640)
        #expect(head?.y == 360)           // already CG top-left — no re-flip
        #expect(head?.confidence == 0.8)
        #expect(head?.ts == 1_750_000_000_000)
        #expect(head?.yaw == nil)
        #expect(head?.pitch == nil)
    }

    @Test func frozenFaceOutputYieldsNoHeadPoint() {
        let frozen = PointerOutput(point: CGPoint(x: 100, y: 100), state: .frozen, confidence: nil)
        #expect(FaceIntentAdapter.headPoint(from: frozen) == nil,
                "a frozen face must not overwrite the last good head point")
    }

    @Test func liveFaceWithNoConfidenceYieldsNoHeadPoint() {
        let noConf = PointerOutput(point: CGPoint(x: 100, y: 100), state: .live, confidence: nil)
        #expect(FaceIntentAdapter.headPoint(from: noConf) == nil)
    }

    // MARK: HandIntentAdapter → GestureReferent

    @Test func liveHandOutputBecomesCursorReferent() {
        let output = PointerOutput(point: CGPoint(x: 420, y: 280), state: .live, confidence: 0.9)
        let referent = HandIntentAdapter.referent(from: output)
        #expect(referent != nil)
        #expect(referent?.cursor?.x == 420)
        #expect(referent?.cursor?.y == 280)
        #expect(referent?.evidence == nil, "the ported hand model emits a cursor, not a locked surface")
        #expect(referent?.isEmpty == false)
    }

    @Test func frozenHandOutputYieldsNoReferent() {
        let frozen = PointerOutput(point: CGPoint(x: 1, y: 1), state: .frozen, confidence: nil)
        #expect(HandIntentAdapter.referent(from: frozen) == nil,
                "a frozen hand (no hand present) must not overwrite the last gesture referent")
    }
}
