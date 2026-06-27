import XCTest
@testable import DirectorSidecar

/// Coarse pointing region → ranked n-best window cluster (FR-4; ARCHITECTURE §5 — the pointing
/// n-best is a TARGET CLUSTER, not a pixel cursor). Ported from the handsoff-rebuild perception
/// suite and adapted to the localized Wire types (`PerceptionWindowRef`/`ScreenEvent`), so the bus
/// can hand the aligner a ranked `[WindowOrRegionRef]` rather than one ambiguous window. A hit
/// dead-center scores ~1; a window whose frame is farther than `radius` (default 24px) from the hit
/// is excluded; ties break by id for determinism (INV-14).
final class NBestClusterTests: XCTestCase {

    private func header() -> EventHeader {
        EventHeader(source: .webcam_2d, tSrc: MonotonicInstant(nanoseconds: 0),
                    conf: 0.9, nBest: 0, taint: .trusted)
    }

    private func win(_ id: String, _ r: CGGlobalRect) -> PerceptionWindowRef {
        PerceptionWindowRef(appBundleId: id, title: id, frame: r, display: 0)
    }

    private func screen(_ windows: [PerceptionWindowRef]) -> ScreenEvent {
        ScreenEvent(header: header(), windows: windows,
                    displays: [DisplayRef(id: 0, bounds: CGGlobalRect(x: 0, y: 0, width: 6000, height: 6000))],
                    focusedField: nil)
    }

    func test_centerHit_scoresNearOne_farWindowExcluded() {
        let a = win("com.a", CGGlobalRect(x: 0, y: 0, width: 1000, height: 800))   // hit at its center
        let b = win("com.b", CGGlobalRect(x: 400, y: 300, width: 1000, height: 800))
        let far = win("com.far", CGGlobalRect(x: 5000, y: 5000, width: 200, height: 200))

        let nbest = NBestCluster.rank(hit: PixelPoint(x: 500, y: 400), in: screen([b, far, a]), radius: 50)

        XCTAssertFalse(nbest.contains { $0.id == "com.far" }, "far window beyond radius excluded")
        XCTAssertEqual(Set(nbest.map(\.id)), ["com.a", "com.b"])
        XCTAssertEqual(nbest[0].id, "com.a", "hit at A's exact center ranks first")
        XCTAssertEqual(nbest[0].conf, 1.0, accuracy: 1e-9, "dead-center hit scores ~1")
        XCTAssertGreaterThanOrEqual(nbest[0].conf, nbest[1].conf)
    }

    func test_beyondDefaultRadius24_excluded_withinIncluded() {
        let near = win("com.near", CGGlobalRect(x: 600, y: 400, width: 100, height: 100))    // 20px right of hit
        let beyond = win("com.beyond", CGGlobalRect(x: 900, y: 400, width: 100, height: 100)) // ~320px away
        // hit at (580,450): 20px left of `near` (within default radius 24), far from `beyond`.
        let nbest = NBestCluster.rank(hit: PixelPoint(x: 580, y: 450), in: screen([near, beyond]))
        XCTAssertEqual(nbest.map(\.id), ["com.near"], "default radius is 24px")
    }

    func test_tieByConfidence_breaksById() {
        // Two identical-geometry windows equidistant from the hit → equal confidence → id breaks tie.
        let z = win("com.z", CGGlobalRect(x: 0, y: 0, width: 200, height: 200))
        let a = win("com.a", CGGlobalRect(x: 0, y: 0, width: 200, height: 200))
        let nbest = NBestCluster.rank(hit: PixelPoint(x: 100, y: 100), in: screen([z, a]))
        XCTAssertEqual(nbest.map(\.id), ["com.a", "com.z"], "equal confidence ties break by id ascending")
    }
}
