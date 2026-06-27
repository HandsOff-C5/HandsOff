// PerceptionCoordinates — the single coordinate vocabulary for the ported perception layer.
//
// Trimmed port of HO-rebuild `App/Sources/Envelope/Coordinates.swift`. Window geometry lives in
// CG global coordinates (top-left origin, flipped-Y); the bug-prone Cocoa→CG flip is made EXPLICIT
// and ISOLATED to the one helper below (`CoordinateConversion.cocoaToCG`). Kept `internal` (the
// DirectorSidecar app target is a single module) and renamed from the Envelope module so the types
// coexist with DirectorSidecar's own bridge coordinate types.

import CoreGraphics

/// A point in CG global coordinates (top-left origin, flipped-Y), in points.
struct CGGlobalPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rect in CG global coordinates (top-left origin), in points.
struct CGGlobalRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A point in backing-store pixels (e.g. a ray→screen-plane hit). Kept distinct from CGGlobalPoint
/// so the points-vs-pixels boundary is type-checked.
struct PixelPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The ONE flipped-Y conversion layer. Isolating the flip here means no other site performs the
/// Cocoa↔CG Y inversion by hand.
enum CoordinateConversion {
    /// Convert a Cocoa (bottom-left origin) window bottom-edge into a CG global (top-left origin)
    /// top-edge Y. Worked example: screenHeight=1080, height=600, cocoaBottomY=200 → 280.
    static func cocoaToCG(cocoaBottomY: Double, height: Double, screenHeight: Double) -> Double {
        screenHeight - (cocoaBottomY + height)
    }
}
