import Testing
import CoreGraphics
@testable import DirectorSidecar

// DisplayMap — multi-monitor union bounds + union-normalized mapping. The TS source
// (display-map.ts) shipped without a test oracle (D1, CLAUDE §4.1), so these are FRESH
// Swift unit tests: pure CGRect math, no live display needed. Negative-origin displays
// are real (CLAUDE.md I7) — always use each screen's frame.origin.

@Test func testUnionBoundsTwoMonitors() {
    // Primary (0,0,1920,1080) + right monitor (1920,0,1440,1080) -> union (0,0,3360,1080).
    let union = DisplayMap.unionBounds([
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
        CGRect(x: 1920, y: 0, width: 1440, height: 1080),
    ])
    #expect(union == CGRect(x: 0, y: 0, width: 3360, height: 1080))
}

@Test func testUnionBoundsNegativeOriginDisplay() {
    // A monitor left of primary at x = -1440 must be included; union origin.x = -1440.
    let union = DisplayMap.unionBounds([
        CGRect(x: -1440, y: 0, width: 1440, height: 1080),
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
    ])
    #expect(union.origin.x == -1440)
    #expect(union == CGRect(x: -1440, y: 0, width: 3360, height: 1080))
}

@Test func testUnionBoundsNegativeOrigin() {
    // Same negative-origin invariant via a left-and-up offset display; covers minY too.
    let union = DisplayMap.unionBounds([
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
        CGRect(x: -800, y: -200, width: 800, height: 600),
    ])
    #expect(union.origin.x == -800)
    #expect(union.origin.y == -200)
    // maxX = 1920, maxY = 1080 -> width 2720, height 1280.
    #expect(union == CGRect(x: -800, y: -200, width: 2720, height: 1280))
}

@Test func testMonitorLocalToUnionNormalized() {
    // Center of the second monitor (1920,0,1440,1080) within union (0,0,3360,1080).
    // local center = (720, 540); global = (2640, 540); normalized = (2640/3360, 540/1080).
    let union = CGRect(x: 0, y: 0, width: 3360, height: 1080)
    let monitor = CGRect(x: 1920, y: 0, width: 1440, height: 1080)
    let n = DisplayMap.monitorLocalToUnionNormalized(
        localPoint: CGPoint(x: 720, y: 540), monitorFrame: monitor, union: union)
    #expect(abs(n.x - (2640.0 / 3360.0)) < 1e-12)   // 0.785714...
    #expect(abs(n.y - 0.5) < 1e-12)
}
