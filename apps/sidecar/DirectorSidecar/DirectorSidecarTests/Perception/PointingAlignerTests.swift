import XCTest
@testable import DirectorSidecar

/// The live consumer of the bus's 300ms fusion ring: it fuses the latest event per modality into one
/// ranked target cluster (hand weighted over head), so the intent path sees a single "what is the
/// user pointing at" answer. Deterministic given an injected clock (INV-14).
final class PointingAlignerTests: XCTestCase {

    private func event(
        source: EventSource,
        tNanos: UInt64,
        targets: [(String, Double)]
    ) -> PointingEvent {
        PointingEvent(
            header: EventHeader(source: source, tSrc: MonotonicInstant(nanoseconds: tNanos),
                                conf: 0.9, nBest: targets.count, taint: .trusted),
            ray: Ray3D(origin: Vector3(x: 0, y: 0, z: 0), direction: Vector3(x: 0, y: 0, z: -1)),
            screenHit: PixelPoint(x: 0, y: 0),
            nBestTargets: targets.map { WindowOrRegionRef(id: $0.0, conf: $0.1) },
            hand: .right)
    }

    /// A fixed clock far enough ahead that all inserted events sit inside the window.
    private func now(_ nanos: UInt64) -> () -> MonotonicInstant { { MonotonicInstant(nanoseconds: nanos) } }

    func test_emptyRing_fusesToNil() {
        let ring = PointingEventRing()
        let aligner = PointingAligner(ring: ring, now: now(1_000_000))
        XCTAssertNil(aligner.fuse())
        XCTAssertNil(aligner.top())
    }

    func test_fuse_mergesAcrossModalities_handWeightedOverHead() {
        let ring = PointingEventRing()
        // Same instant; both within a wide window. Hand likes A (0.5); head likes A (0.5) and B (0.9).
        ring.insert(event(source: .hand_pose, tNanos: 1_000, targets: [("A", 0.5)]))
        ring.insert(event(source: .face_gaze, tNanos: 1_000, targets: [("A", 0.5), ("B", 0.9)]))
        let aligner = PointingAligner(ring: ring, now: now(2_000))
        let fused = aligner.fuse(window: 10_000)!
        // A = 0.5·1.0 (hand) + 0.5·0.6 (head) = 0.8 ; B = 0.9·0.6 = 0.54 → A leads.
        XCTAssertEqual(fused.targets.map(\.id), ["A", "B"])
        XCTAssertEqual(fused.targets[0].conf, 0.8, accuracy: 1e-9)
        XCTAssertEqual(fused.targets[1].conf, 0.54, accuracy: 1e-9)
        XCTAssertEqual(aligner.top(window: 10_000)?.id, "A")
    }

    func test_latestEventPerSource_supersedesOlder() {
        let ring = PointingEventRing()
        // Two hand frames in the window; the NEWER (B) supersedes the older (A) for that modality.
        ring.insert(event(source: .hand_pose, tNanos: 1_000, targets: [("A", 0.9)]))
        ring.insert(event(source: .hand_pose, tNanos: 2_000, targets: [("B", 0.7)]))
        let aligner = PointingAligner(ring: ring, now: now(3_000))
        let fused = aligner.fuse(window: 10_000)!
        XCTAssertEqual(fused.targets.map(\.id), ["B"], "newer hand frame wins; older not double-counted")
    }

    func test_tieBreaksByIdAscending() {
        let ring = PointingEventRing()
        ring.insert(event(source: .hand_pose, tNanos: 1_000, targets: [("z", 0.5), ("a", 0.5)]))
        let aligner = PointingAligner(ring: ring, now: now(2_000))
        XCTAssertEqual(aligner.fuse(window: 10_000)!.targets.map(\.id), ["a", "z"])
    }
}
