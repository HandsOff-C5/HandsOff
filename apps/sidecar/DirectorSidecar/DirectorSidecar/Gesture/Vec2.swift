//
//  Vec2.swift
//  DirectorSidecar
//
//  The gesture lane's 2D point — the Swift stand-in for the TS `Point = readonly
//  [number, number]` that flows through calibration, pointing, display arbitration, and the
//  referent loop. A dedicated value type (not CGPoint) keeps the linear algebra explicit and
//  avoids any CGFloat ambiguity; it lives in EITHER the raw pointing-signal space or the
//  global virtual-desktop px screen space depending on the producer (the same overload the
//  TS `Point` carried).
//

import Foundation

struct Vec2: Equatable, Sendable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// Decode/encode from the wire `[x, y]` array shape the fixtures store.
    init(array a: [Double]) throws {
        guard a.count == 2 else { throw GestureContractError.outOfRange("Vec2 expects [x, y]") }
        self.init(a[0], a[1])
    }
}
