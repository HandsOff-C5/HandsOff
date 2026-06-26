//
//  G5bDisplayGeometryTests.swift
//  DirectorSidecarTests
//
//  Multi-display overlay geometry (folded in from the gesture-overlay sidecar). Pure resolution of
//  a contract-space point → owning display + top-left-origin LOCAL offset: half-open edge ownership
//  (a boundary point belongs to exactly one display), gap-fallback to the nearest display clamped to
//  its bounds, negative-offset monitors (left/above the primary), and the empty-display nil.
//

import Testing
import CoreGraphics
@testable import DirectorSidecar

// A 1920×1080 primary at the contract origin + a 1280×720 secondary to its right (x:1920).
private let primary = DisplayRect(id: 1, isMain: true, x: 0, y: 0, width: 1920, height: 1080)
private let rightSecondary = DisplayRect(id: 2, isMain: false, x: 1920, y: 0, width: 1280, height: 720)
private let twoAcross = [primary, rightSecondary]

// MARK: half-open containment

@Test func containsIsHalfOpenOnEdges() {
    // Top-left corner is INSIDE; the right/bottom edges belong to the NEXT display (half-open).
    #expect(primary.contains(0, 0))
    #expect(primary.contains(1919.9, 1079.9))
    #expect(!primary.contains(1920, 0))   // right edge → not owned by the primary
    #expect(!primary.contains(0, 1080))   // bottom edge → not owned by the primary
}

@Test func sharedEdgeBelongsToExactlyOneDisplay() {
    // x:1920 is the seam: the primary excludes it (half-open), the right secondary includes it.
    let loc = DisplayGeometry.locate(1920, 360, in: twoAcross)
    #expect(loc?.displayID == 2)
    #expect(loc?.localX == 0)     // local origin of the secondary
    #expect(loc?.localY == 360)
}

// MARK: in-bounds resolution → local offset

@Test func pointOnSecondaryResolvesToLocalOffset() {
    let loc = DisplayGeometry.locate(2560, 400, in: twoAcross) // 2560 = 1920 + 640
    #expect(loc?.displayID == 2)
    #expect(loc?.localX == 640) // 2560 - 1920
    #expect(loc?.localY == 400)
}

@Test func pointOnPrimaryPassesThroughUntranslated() {
    let loc = DisplayGeometry.locate(300, 210, in: twoAcross)
    #expect(loc?.displayID == 1)
    #expect(loc?.localX == 300)
    #expect(loc?.localY == 210)
}

// MARK: gap fallback (clamp to nearest)

@Test func pointBelowPrimaryGapClampsToNearestEdge() {
    // y:2000 is below both displays (max height 1080). Nearest is the primary; Y clamps to 1080.
    let loc = DisplayGeometry.locate(500, 2000, in: twoAcross)
    #expect(loc?.displayID == 1)
    #expect(loc?.localX == 500)
    #expect(loc?.localY == 1080) // clamped to the bottom edge, never dropped
}

@Test func pointRightOfAllDisplaysClampsToFarDisplay() {
    // x:5000 is right of the secondary (ends at 3200); clamp X to its right edge (1280 local).
    let loc = DisplayGeometry.locate(5000, 300, in: twoAcross)
    #expect(loc?.displayID == 2)
    #expect(loc?.localX == 1280)
    #expect(loc?.localY == 300)
}

// MARK: negative-offset displays (monitor left of / above the primary)

@Test func displayLeftOfPrimaryHasNegativeOriginAndLocalizes() {
    let leftSecondary = DisplayRect(id: 3, isMain: false, x: -1280, y: 0, width: 1280, height: 720)
    let layout = [primary, leftSecondary]
    let loc = DisplayGeometry.locate(-300, 100, in: layout)
    #expect(loc?.displayID == 3)
    #expect(loc?.localX == 980) // -300 - (-1280)
    #expect(loc?.localY == 100)
}

@Test func displayAbovePrimaryHasNegativeYAndLocalizes() {
    let topSecondary = DisplayRect(id: 4, isMain: false, x: 0, y: -720, width: 1280, height: 720)
    let layout = [primary, topSecondary]
    let loc = DisplayGeometry.locate(200, -100, in: layout)
    #expect(loc?.displayID == 4)
    #expect(loc?.localX == 200)
    #expect(loc?.localY == 620) // -100 - (-720)
}

// MARK: degenerate input

@Test func emptyDisplaysReturnsNil() {
    #expect(DisplayGeometry.locate(0, 0, in: []) == nil)
}

@Test func squaredDistanceIsZeroInsideAndGrowsOutside() {
    #expect(primary.squaredDistance(100, 100) == 0)
    #expect(primary.squaredDistance(1920, 0) == 0) // on the (excluded) edge: distance still 0
    #expect(primary.squaredDistance(1922, 0) == 4) // 2px right of the edge → 2² = 4
}
