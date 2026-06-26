//
//  GestureConfidenceTests.swift
//  DirectorSidecarTests
//
//  Port of packages/gesture/src/confidence/{smoothing,dwell,calibration}.test.ts.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - smoothing.test.ts

@Test func emaAlphaOneIsPassthrough() {
    #expect(GestureSmoothing.ema(10, 3, 1) == 10)
}

@Test func emaAlphaZeroIsFrozen() {
    #expect(GestureSmoothing.ema(10, 3, 0) == 3)
}

@Test func emaAlphaHalfIsMidpoint() {
    #expect(GestureSmoothing.ema(10, 0, 0.5) == 5)
}

@Test func alphaFromCutoffInUnitInterval() {
    let a = GestureSmoothing.alphaFromCutoff(1, 1)
    #expect(a > 0)
    #expect(a < 1)
}

@Test func alphaFromCutoffMatchesDefinition() {
    #expect(gClose(GestureSmoothing.alphaFromCutoff(1, 1), 0.8627, 3))
}

@Test func higherCutoffYieldsLargerAlpha() {
    #expect(GestureSmoothing.alphaFromCutoff(5, 1) > GestureSmoothing.alphaFromCutoff(0.5, 1))
}

@Test func oneEuroReturnsFirstSampleUnchanged() {
    let f = OneEuroFilter(minCutoff: 1, beta: 0)
    #expect(f.filter(5, 0) == 5)
}

@Test func oneEuroConvergesToConstant() {
    let f = OneEuroFilter(minCutoff: 1, beta: 0)
    _ = f.filter(5, 0)
    var t = 50.0
    while t <= 500 { _ = f.filter(5, t); t += 50 }
    #expect(gClose(f.filter(5, 550), 5))
}

@Test func oneEuroFasterMotionLessSmoothing() {
    let slow = OneEuroFilter(minCutoff: 1, beta: 0)
    let fast = OneEuroFilter(minCutoff: 1, beta: 0.5)
    var slowOut = 0.0, fastOut = 0.0
    for k in 0...20 {
        slowOut = slow.filter(Double(k), Double(k) * 50)
        fastOut = fast.filter(Double(k), Double(k) * 50)
    }
    #expect(abs(20 - fastOut) < abs(20 - slowOut))
}

// MARK: - dwell.test.ts

private let dwellParams = DwellDebounceParams(enter: 0.7, exit: 0.4, dwellMs: 200, cooldownMs: 500)

@Test func dwellSingleHighFrameNeverFires() {
    let d = DwellDebounce(dwellParams)
    let r = d.update(0.9, 50)
    #expect(r.active == true)
    #expect(r.fired == false)
}

@Test func dwellSustainedFiresExactlyOnce() {
    let d = DwellDebounce(dwellParams)
    var fires = 0
    for _ in 0..<40 where d.update(0.9, 50).fired { fires += 1 }
    #expect(fires == 1)
}

@Test func dwellHysteresisNoFlicker() {
    let d = DwellDebounce(dwellParams)
    _ = d.update(0.9, 50)
    for c in [0.5, 0.45, 0.6, 0.5] {
        #expect(d.update(c, 50).active == true)
    }
    #expect(d.update(0.3, 50).active == false)
}

@Test func dwellNoisySpikeCannotFire() {
    let d = DwellDebounce(dwellParams)
    let fired = [0.1, 0.95, 0.1, 0.1, 0.2].map { d.update($0, 50).fired }
    #expect(fired.contains(true) == false)
}

@Test func dwellCooldownBlocksImmediateRefire() {
    let d = DwellDebounce(DwellDebounceParams(enter: 0.7, exit: 0.4, dwellMs: 100, cooldownMs: 500))
    var fireFrames: [Double] = []
    var tMs = 0.0
    let pattern = [
        0.9, 0.9, 0.9,
        0.1, 0.9, 0.9, 0.9, 0.9, 0.9,
        0.1, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9,
    ]
    for c in pattern {
        if d.update(c, 50).fired { fireFrames.append(tMs) }
        tMs += 50
    }
    #expect(fireFrames.count == 2)
    #expect(fireFrames[1] - fireFrames[0] >= 500)
}

// MARK: - calibration.test.ts (temperature scaling)

@Test func calibrateConfidenceTemperatureOnePassthrough() throws {
    for p in [0.05, 0.2, 0.5, 0.73, 0.99] {
        #expect(gClose(try ConfidenceCalibration.calibrateConfidence(p, 1), p, 10))
    }
}

@Test func calibrateConfidenceHalfIsFixedPoint() throws {
    for t in [0.25, 0.5, 1, 2, 5] {
        #expect(gClose(try ConfidenceCalibration.calibrateConfidence(0.5, Double(t)), 0.5, 10))
    }
}

@Test func calibrateConfidenceTGreaterSoftens() throws {
    let hi = try ConfidenceCalibration.calibrateConfidence(0.9, 2)
    #expect(hi < 0.9 && hi > 0.5)
    let lo = try ConfidenceCalibration.calibrateConfidence(0.1, 2)
    #expect(lo > 0.1 && lo < 0.5)
}

@Test func calibrateConfidenceTLessSharpens() throws {
    #expect(try ConfidenceCalibration.calibrateConfidence(0.9, 0.5) > 0.9)
    #expect(try ConfidenceCalibration.calibrateConfidence(0.1, 0.5) < 0.1)
}

@Test func calibrateConfidenceMonotonic() throws {
    let t = 1.8
    var prev = -Double.infinity
    var p = 0.01
    while p <= 0.99 {
        let out = try ConfidenceCalibration.calibrateConfidence(p, t)
        #expect(out > prev)
        prev = out
        p += 0.01
    }
}

@Test func calibrateConfidenceKeepsEndpoints() throws {
    #expect(try ConfidenceCalibration.calibrateConfidence(0, 2) == 0)
    #expect(try ConfidenceCalibration.calibrateConfidence(1, 2) == 1)
}

@Test func calibrateConfidenceAlwaysInUnitInterval() throws {
    for t in [0.3, 1, 3] {
        var p = 0.0
        while p <= 1 {
            let out = try ConfidenceCalibration.calibrateConfidence(p, Double(t))
            #expect(out >= 0 && out <= 1)
            p += 0.1
        }
    }
}

@Test func calibrateConfidenceClampsOutOfRangeRaw() throws {
    #expect(try ConfidenceCalibration.calibrateConfidence(1.5, 1) == 1)
    #expect(try ConfidenceCalibration.calibrateConfidence(-0.5, 1) == 0)
}

@Test func calibrateConfidenceThrowsOnNonPositiveTemperature() {
    #expect(throws: (any Error).self) { try ConfidenceCalibration.calibrateConfidence(0.8, 0) }
    #expect(throws: (any Error).self) { try ConfidenceCalibration.calibrateConfidence(0.8, -1) }
}
