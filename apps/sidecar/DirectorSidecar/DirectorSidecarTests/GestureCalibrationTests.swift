//
//  GestureCalibrationTests.swift
//  DirectorSidecarTests
//
//  Port of packages/gesture/src/calibration/{calibrate,capture,multi-monitor}.test.ts +
//  display/arbitration.test.ts.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - calibrate.test.ts

private let KNOWN = CalibrationAffine(a: 1.2, b: -0.3, c: 40, d: 0.25, e: 0.9, f: -15)

private func applyKnown(_ t: CalibrationAffine, _ p: Vec2) -> Vec2 {
    Vec2(t.a * p.x + t.b * p.y + t.c, t.d * p.x + t.e * p.y + t.f)
}

private let RAW: [Vec2] = [Vec2(0, 0), Vec2(100, 0), Vec2(0, 100), Vec2(100, 100), Vec2(50, 50)]

private func exactPairs() -> [CalibrationPair] {
    RAW.map { CalibrationPair(raw: $0, target: applyKnown(KNOWN, $0)) }
}

@Test func fitAffineRecoversKnownMatrix() throws {
    let fit = try GestureCalibration.fitAffine(exactPairs())
    #expect(gClose(fit.a, KNOWN.a))
    #expect(gClose(fit.b, KNOWN.b))
    #expect(gClose(fit.c, KNOWN.c))
    #expect(gClose(fit.d, KNOWN.d))
    #expect(gClose(fit.e, KNOWN.e))
    #expect(gClose(fit.f, KNOWN.f))
}

@Test func fitAffineResidualNearZeroForExact() throws {
    let pairs = exactPairs()
    #expect(gClose(GestureCalibration.calibrationResidual(try GestureCalibration.fitAffine(pairs), pairs), 0))
}

@Test func fitAffinePositiveResidualWhenPerturbed() throws {
    var pairs = exactPairs()
    pairs[2] = CalibrationPair(raw: pairs[2].raw, target: Vec2(pairs[2].target.x + 30, pairs[2].target.y - 30))
    #expect(GestureCalibration.calibrationResidual(try GestureCalibration.fitAffine(pairs), pairs) > 0)
}

@Test func fitAffineThrowsBelowThreeCorrespondences() {
    #expect(throws: (any Error).self) { try GestureCalibration.fitAffine(Array(exactPairs().prefix(2))) }
}

private let KNOWN_H = Homography(values: [1.2, -0.3, 40, 0.25, 0.9, -15, 0.0005, -0.0003, 1])

private func applyKnownH(_ h: Homography, _ p: Vec2) -> Vec2 {
    let w = h[6] * p.x + h[7] * p.y + h[8]
    return Vec2((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w)
}

private func exactHomographyPairs() -> [CalibrationPair] {
    RAW.map { CalibrationPair(raw: $0, target: applyKnownH(KNOWN_H, $0)) }
}

@Test func applyHomographyMatchesReference() {
    #expect(GestureCalibration.applyHomography(KNOWN_H, Vec2(10, 20)) == applyKnownH(KNOWN_H, Vec2(10, 20)))
}

@Test func fitHomographyRecoversKnownUpToScale() throws {
    let fit = try GestureCalibration.fitHomography(exactHomographyPairs())
    for i in 0..<9 { #expect(gClose(fit[i], KNOWN_H[i])) }
}

@Test func fitHomographyFitsPerspectiveAffineCannot() throws {
    let pairs = exactHomographyPairs()
    let h = try GestureCalibration.fitHomography(pairs)
    #expect(gClose(GestureCalibration.homographyResidual(h, pairs), 0))
    #expect(GestureCalibration.calibrationResidual(try GestureCalibration.fitAffine(pairs), pairs) > 1)
}

@Test func fitHomographyPositiveResidualWhenPerturbed() throws {
    var pairs = exactHomographyPairs()
    pairs[2] = CalibrationPair(raw: pairs[2].raw, target: Vec2(pairs[2].target.x + 30, pairs[2].target.y - 30))
    #expect(GestureCalibration.homographyResidual(try GestureCalibration.fitHomography(pairs), pairs) > 0)
}

@Test func fitHomographyThrowsBelowFourCorrespondences() {
    #expect(throws: (any Error).self) { try GestureCalibration.fitHomography(Array(exactHomographyPairs().prefix(3))) }
}

@Test func applyTransformExact() {
    #expect(GestureCalibration.applyTransform(KNOWN, Vec2(10, 20)) == Vec2(46, 5.5))
}

@Test func calibrationQualityBuckets() {
    #expect(GestureCalibration.calibrationQualityFromResidual(5) == .good)
    #expect(GestureCalibration.calibrationQualityFromResidual(20) == .good)
    #expect(GestureCalibration.calibrationQualityFromResidual(40) == .fair)
    #expect(GestureCalibration.calibrationQualityFromResidual(60) == .fair)
    #expect(GestureCalibration.calibrationQualityFromResidual(100) == .poor)
}

private let hitSurfaces: [Contracts.Surface] = [
    Contracts.Surface(id: "a", bounds: Contracts.SurfaceBounds(x: 0, y: 0, w: 100, h: 100), displayId: "d0"),
    Contracts.Surface(id: "b", bounds: Contracts.SurfaceBounds(x: 500, y: 0, w: 100, h: 100), displayId: "d0"),
]

@Test func toCandidateNearestWhenOutsideAll() throws {
    let candidate = try #require(GestureCalibration.toCandidate(Vec2(200, 50), hitSurfaces, .fair))
    #expect(candidate.targetId == "a")
    #expect(candidate.calibrationQuality == .fair)
    #expect(gClose(candidate.confidence, 2.0 / 3.0))
}

@Test func toCandidateFullConfidenceInside() {
    #expect(GestureCalibration.toCandidate(Vec2(50, 50), hitSurfaces, .good)?.confidence == 1)
}

@Test func toCandidateNullWhenNoSurfaces() {
    #expect(GestureCalibration.toCandidate(Vec2(50, 50), [], .good) == nil)
}

private struct CalibrationGoldenCase: Decodable {
    let name: String
    let screenXY: [Double]
    let calibrationQuality: Contracts.CalibrationQuality
    let surfaces: [Contracts.Surface]
    let expected: Contracts.PointingCandidate?
}

@Test func toCandidateGoldenRecords() throws {
    let cases = try GestureFixtures.decode([CalibrationGoldenCase].self, "calibration.golden.json")
    #expect(cases.count > 0)
    for c in cases {
        let actual = GestureCalibration.toCandidate(try Vec2(array: c.screenXY), c.surfaces, c.calibrationQuality)
        #expect(actual == c.expected, "\(c.name)")
    }
}

// MARK: - capture.test.ts

private let captureBounds = Contracts.SurfaceBounds(x: 0, y: 0, w: 1920, h: 1080)

@Test func gridTargetsLaysGrid() {
    #expect(CalibrationCapture.gridTargets(captureBounds, GridSpec(cols: 3, rows: 3)).count == 9)
}

@Test func gridTargetsSpansCornerToCornerMarginZero() {
    let t = CalibrationCapture.gridTargets(captureBounds, GridSpec(cols: 3, rows: 3, margin: 0))
    #expect(t[0] == Vec2(0, 0))
    #expect(t[4] == Vec2(960, 540))
    #expect(t[8] == Vec2(1920, 1080))
}

@Test func gridTargetsInsetsByMargin() {
    let t = CalibrationCapture.gridTargets(captureBounds, GridSpec(cols: 3, rows: 3, margin: 0.1))
    #expect(t[0] == Vec2(192, 108))
    #expect(t[8] == Vec2(1728, 972))
}

@Test func calibrationSessionStartsAtFirstTarget() throws {
    let targets = CalibrationCapture.gridTargets(captureBounds, GridSpec(cols: 3, rows: 3, margin: 0))
    let session = CalibrationSession(targets: targets)
    let p = session.current()
    #expect(p.index == 0 && p.total == 9 && p.done == false && p.target == Vec2(0, 0))
    #expect(try session.result() == nil)
}

@Test func calibrationSessionAdvancesThroughTargets() throws {
    let targets = CalibrationCapture.gridTargets(captureBounds, GridSpec(cols: 3, rows: 3, margin: 0))
    let session = CalibrationSession(targets: targets)
    #expect(try session.capture(Vec2(0, 0)).index == 1)
    for _ in 1..<9 { _ = try session.capture(Vec2(0, 0)) }
    #expect(session.current().done == true)
    #expect(session.current().target == nil)
}

@Test func calibrationSessionFitsRecoveringTransform() throws {
    let targets = CalibrationCapture.gridTargets(captureBounds, GridSpec(cols: 3, rows: 3, margin: 0))
    let session = CalibrationSession(targets: targets)
    for t in targets { _ = try session.capture(Vec2(t.x / 1920, t.y / 1080)) }
    let result = try #require(try session.result())
    #expect(gClose(result.transform.a, 1920, 3))
    #expect(gClose(result.transform.e, 1080, 3))
    #expect(gClose(result.transform.b, 0))
    #expect(gClose(result.transform.d, 0))
    #expect(gClose(result.residual, 0, 3))
    #expect(result.quality == .good)
}

@Test func calibrationSessionThrowsAfterAllCaptured() throws {
    let targets = CalibrationCapture.gridTargets(captureBounds, GridSpec(cols: 3, rows: 3, margin: 0))
    let session = CalibrationSession(targets: targets)
    for _ in 0..<9 { _ = try session.capture(Vec2(0, 0)) }
    #expect(throws: (any Error).self) { try session.capture(Vec2(0, 0)) }
}

// MARK: - multi-monitor.test.ts

private let primaryDisplay = Display(id: "1", bounds: Contracts.SurfaceBounds(x: 0, y: 0, w: 1920, h: 1080))
private let secondaryDisplay = Display(id: "2", bounds: Contracts.SurfaceBounds(x: -1920, y: 0, w: 1920, h: 1080))

private func buildPairs(_ display: Display, _ count: Int) -> [MultiCalibrationPair] {
    let grid: [Vec2] = [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1), Vec2(1, 1), Vec2(0.5, 0.5)]
    return (0..<count).map { i in
        let r = grid[i % grid.count]
        return MultiCalibrationPair(
            raw: r,
            displayId: display.id,
            target: Vec2(display.bounds.x + r.x * display.bounds.w, display.bounds.y + r.y * display.bounds.h)
        )
    }
}

@Test func multiMonitorTargetsLaysGridAcrossDisplays() {
    let targets = MultiMonitor.multiMonitorTargets([primaryDisplay, secondaryDisplay], GridSpec(cols: 3, rows: 3, margin: 0))
    #expect(targets.count == 18)
    #expect(targets[0].displayId == "1" && targets[0].target == Vec2(0, 0))
    #expect(targets.first { $0.displayId == "2" }?.target.x == -1920)
}

@Test func fitMultiMonitorRecoversSingleDisplay() throws {
    let cal = try MultiMonitor.fitMultiMonitor(buildPairs(primaryDisplay, 9))
    let fit = try #require(cal.byDisplay["1"])
    #expect(gClose(fit.transform.a, 1920, 3))
    #expect(gClose(fit.transform.e, 1080, 3))
    #expect(gClose(fit.transform.c, 0, 3))
    #expect(gClose(fit.transform.f, 0, 3))
    #expect(cal.quality == .good)
}

@Test func fitMultiMonitorRecoversNegativeSecondaryOrigin() throws {
    let cal = try MultiMonitor.fitMultiMonitor(buildPairs(primaryDisplay, 5) + buildPairs(secondaryDisplay, 5))
    #expect(gClose(try #require(cal.byDisplay["1"]).transform.c, 0, 3))
    #expect(gClose(try #require(cal.byDisplay["2"]).transform.c, -1920, 3))
    #expect(gClose(try #require(cal.byDisplay["2"]).transform.a, 1920, 3))
}

@Test func fitMultiMonitorThrowsWhenDisplayUnderThree() {
    #expect(throws: (any Error).self) { try MultiMonitor.fitMultiMonitor(buildPairs(primaryDisplay, 2)) }
}

private func separatedFit() throws -> MultiMonitorCalibration {
    let primaryRaws: [Vec2] = [Vec2(0.6, 0), Vec2(1, 0), Vec2(0.6, 1), Vec2(1, 1), Vec2(0.8, 0.5)]
    let secondaryRaws: [Vec2] = [Vec2(0, 0), Vec2(0.4, 0), Vec2(0, 1), Vec2(0.4, 1), Vec2(0.2, 0.5)]
    let pairs = primaryRaws.map { MultiCalibrationPair(raw: $0, displayId: "1", target: Vec2($0.x * 1920, $0.y * 1080)) }
        + secondaryRaws.map { MultiCalibrationPair(raw: $0, displayId: "2", target: Vec2($0.x * 1920 - 1920, $0.y * 1080)) }
    return try MultiMonitor.fitMultiMonitor(pairs)
}

@Test func predictMultiMonitorRoutesLeftToSecondary() throws {
    let cal = try separatedFit()
    let g = MultiMonitor.predictMultiMonitor(cal, Vec2(0.2, 0.5))
    #expect(g.x < 0)
    #expect(gClose(g.x, 0.2 * 1920 - 1920, 1))
}

@Test func predictMultiMonitorRoutesRightToPrimary() throws {
    let cal = try separatedFit()
    let g = MultiMonitor.predictMultiMonitor(cal, Vec2(0.8, 0.5))
    #expect(g.x >= 0)
    #expect(gClose(g.x, 0.8 * 1920, 1))
}

@Test func predictMultiMonitorPassthroughWhenNoCalibration() {
    #expect(MultiMonitor.predictMultiMonitor(nil, Vec2(0.3, 0.4)) == Vec2(0.3, 0.4))
}

// MARK: - display/arbitration.test.ts

private let PRIMARY = Display(id: "primary", bounds: Contracts.SurfaceBounds(x: 0, y: 0, w: 1920, h: 1080))
private let RIGHT = Display(id: "right", bounds: Contracts.SurfaceBounds(x: 1920, y: 0, w: 1920, h: 1080))
private let LEFT = Display(id: "left", bounds: Contracts.SurfaceBounds(x: -1920, y: 0, w: 1920, h: 1080))
private let TOP = Display(id: "top", bounds: Contracts.SurfaceBounds(x: 0, y: -1080, w: 1920, h: 1080))

@Test func pickDisplayNullWhenNoDisplays() {
    #expect(DisplayArbitration.pickDisplay(Vec2(100, 100), []) == nil)
}

@Test func pickDisplayPicksContaining() {
    #expect(DisplayArbitration.pickDisplay(Vec2(960, 540), [PRIMARY, RIGHT]) == "primary")
    #expect(DisplayArbitration.pickDisplay(Vec2(2880, 540), [PRIMARY, RIGHT]) == "right")
}

@Test func pickDisplayHandlesNegativeX() {
    #expect(DisplayArbitration.pickDisplay(Vec2(-500, 540), [PRIMARY, LEFT]) == "left")
}

@Test func pickDisplayHandlesNegativeY() {
    #expect(DisplayArbitration.pickDisplay(Vec2(500, -200), [PRIMARY, TOP]) == "top")
}

@Test func pickDisplayNearestAcrossGap() {
    let far = Display(id: "far", bounds: Contracts.SurfaceBounds(x: 2920, y: 0, w: 1920, h: 1080))
    #expect(DisplayArbitration.pickDisplay(Vec2(2400, 540), [PRIMARY, far]) == "primary")
}

@Test func pickDisplayHysteresisKeepsCurrent() {
    #expect(DisplayArbitration.pickDisplay(Vec2(1930, 540), [PRIMARY, RIGHT], currentId: "primary", marginPx: 50) == "primary")
}

@Test func pickDisplayHysteresisSwitchesPastMargin() {
    #expect(DisplayArbitration.pickDisplay(Vec2(2000, 540), [PRIMARY, RIGHT], currentId: "primary", marginPx: 50) == "right")
}

@Test func pickDisplayNoCurrentPicksContainment() {
    #expect(DisplayArbitration.pickDisplay(Vec2(1930, 540), [PRIMARY, RIGHT], currentId: nil, marginPx: 50) == "right")
}

@Test func pickDisplayIgnoresStaleCurrentId() {
    #expect(DisplayArbitration.pickDisplay(Vec2(960, 540), [PRIMARY, RIGHT], currentId: "unplugged", marginPx: 50) == "primary")
}
