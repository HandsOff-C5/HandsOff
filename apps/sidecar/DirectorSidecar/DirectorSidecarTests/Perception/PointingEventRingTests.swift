import XCTest
@testable import DirectorSidecar

/// S2·T5 — the 300ms fusion ring. Concurrent perception emits `PointingEvent`s from per-plugin
/// queues; the aligner (S4) fuses a gesture with a voice command within a ±300ms window, so the
/// ring keeps only the recent past: events older than `fusionWindowMillis` (300) are evicted, and
/// `within(window:)` returns the survivors ordered by source time. Because inserts arrive off
/// multiple queues it must be concurrent-insert safe (a lock — in-process, no transport, I5).
/// (RESEARCH_CONVERGENCE §7; MIGRATION §4.)
final class PointingEventRingTests: XCTestCase {

    /// A pointing event stamped at `ms` milliseconds on the monotonic clock.
    private func event(atMs ms: Double, id: String = "w") -> PointingEvent {
        let header = EventHeader(
            source: .hand_pose,
            tSrc: MonotonicInstant(nanoseconds: UInt64(ms * 1_000_000)),
            conf: 0.9, nBest: 0, taint: .trusted)
        return PointingEvent(
            header: header,
            ray: Ray3D(origin: Vector3(x: 0, y: 0, z: 0), direction: Vector3(x: 0, y: 0, z: -1)),
            screenHit: PixelPoint(x: 1, y: 1),
            nBestTargets: [WindowOrRegionRef(id: id, conf: 0.9)],
            hand: .right)
    }

    func test_fusionWindow_is300ms() {
        XCTAssertEqual(PointingEventRing.fusionWindowMillis, 300)
    }

    func test_eventsOlderThanWindow_areEvicted() {
        let ring = PointingEventRing()
        ring.insert(event(atMs: 0, id: "old"))
        ring.insert(event(atMs: 100, id: "mid"))
        ring.insert(event(atMs: 400, id: "new")) // newest; cutoff = 400 − 300 = 100ms

        let survivors = ring.within(now: MonotonicInstant(nanoseconds: UInt64(400 * 1_000_000)))
        XCTAssertEqual(survivors.map { $0.nBestTargets.first?.id }, ["mid", "new"],
                       "the 0ms event is >300ms old → evicted; 100ms is exactly at the boundary → kept")
    }

    func test_within_returnsOrderedByTSrc() {
        let ring = PointingEventRing()
        // insert out of order
        ring.insert(event(atMs: 250, id: "c"))
        ring.insert(event(atMs: 50, id: "a"))
        ring.insert(event(atMs: 150, id: "b"))

        let ordered = ring.within(now: MonotonicInstant(nanoseconds: UInt64(250 * 1_000_000)))
        XCTAssertEqual(ordered.map { $0.nBestTargets.first?.id }, ["a", "b", "c"],
                       "within() returns survivors ordered by source time")
    }

    func test_concurrentInsert_isSafe() {
        let ring = PointingEventRing()
        let base = 1_000_000.0 // 1e6 ms — all recent relative to each other
        let n = 500
        DispatchQueue.concurrentPerform(iterations: n) { i in
            ring.insert(event(atMs: base + Double(i) * 0.0001, id: "e\(i)"))
        }
        // No crash, and every event lands (all within the window of the newest).
        let survivors = ring.within(now: MonotonicInstant(nanoseconds: UInt64((base + 1) * 1_000_000)))
        XCTAssertEqual(survivors.count, n, "every concurrent insert is retained, no torn writes")
    }
}
