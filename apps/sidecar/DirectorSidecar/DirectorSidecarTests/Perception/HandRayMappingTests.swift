import Testing
import CoreGraphics
@testable import DirectorSidecar

// EXPERIMENTAL (branch experiment/head-ray-gaze) — index-finger "laser pointer" math, ABSOLUTE
// point-at-the-spot. Pure, headless: pin that `aim` is the fingertip led FORWARD along the pointing
// direction (lead 0 ≡ the fingertip itself), that pointing right/up moves the aim the matching way,
// that the flip knob mirrors horizontal, and that the multi-joint averaging equals the plain
// MCP→TIP fallback for a straight finger. Synthetic HandSignals set the ray joints explicitly.

/// A synthetic finger pose. `mcp`→`tip` is the finger; PIP/DIP are left to interpolate (confidence
/// `refineConf`, default 0 → the ray uses the plain MCP→TIP fallback direction).
private func handPose(
    tip: CGPoint, mcp: CGPoint,
    little: CGPoint? = nil, littleConf: Double = 0,
    pip: CGPoint? = nil, dip: CGPoint? = nil, refineConf: Double = 0
) -> HandSignal {
    HandSignal(
        indexTip: tip, indexMCP: mcp,
        indexPIP: pip, indexDIP: dip, littleMCP: little,
        indexTipConfidence: 0.9, indexMCPConfidence: 0.9,
        indexPIPConfidence: refineConf, indexDIPConfidence: refineConf,
        littleMCPConfidence: littleConf)
}

/// A finger pointing straight "up" the frame (tip above MCP, top-left y-down): direction (0,−1),
/// length 0.3.
private func upFinger() -> HandSignal {
    handPose(tip: CGPoint(x: 0.5, y: 0.3), mcp: CGPoint(x: 0.5, y: 0.6))
}

@Test func handRay_leadZeroIsTheFingertip() {
    // lead 0 → the aim is exactly the fingertip (the 2D mode), so the ray degrades cleanly.
    let m = HandRayMapping(lead: 0)
    let s = upFinger()
    let aim = m.aim(s)
    #expect(abs(aim.x - Double(s.indexTip.x)) < 1e-9)
    #expect(abs(aim.y - Double(s.indexTip.y)) < 1e-9)
}

@Test func handRay_leadsForwardAlongTheFinger() {
    // An up-pointing finger (dir (0,−1), len 0.3) led by 1.5 lengths → aim sits 0.45 ABOVE the tip
    // (smaller y in top-left), x unchanged.
    let m = HandRayMapping(lead: 1.5)
    let s = upFinger()
    let aim = m.aim(s)
    #expect(abs(aim.x - 0.5) < 1e-9)               // straight up → no x lead
    #expect(abs(aim.y - (0.3 - 1.5 * 0.3)) < 1e-9) // 0.3 − 0.45 = −0.15, led up past the tip
    #expect(aim.y < Double(s.indexTip.y))          // leads UP (the pointing direction)
}

@Test func handRay_pointingRightAimsRight() {
    // A finger pointing right (tip right of MCP) → the aim leads to the RIGHT of the fingertip; the
    // opposite (pointing left) leads to the left, symmetrically about the fingertip.
    let right = HandRayMapping(lead: 1.0).aim(
        handPose(tip: CGPoint(x: 0.7, y: 0.6), mcp: CGPoint(x: 0.5, y: 0.6)))   // dir (1,0), len 0.2
    let left = HandRayMapping(lead: 1.0).aim(
        handPose(tip: CGPoint(x: 0.3, y: 0.6), mcp: CGPoint(x: 0.5, y: 0.6)))   // dir (−1,0), len 0.2
    #expect(right.x > 0.7)                           // led further right than the tip
    #expect(left.x < 0.3)                            // led further left than the tip
    #expect(abs(right.y - 0.6) < 1e-9)               // horizontal finger → no y lead
}

@Test func handRay_flipXMirrorsHorizontal() {
    // flipX mirrors the aim's x around the frame center (0.5); y is untouched.
    let s = handPose(tip: CGPoint(x: 0.7, y: 0.4), mcp: CGPoint(x: 0.5, y: 0.6))
    let normal = HandRayMapping(lead: 1.0, flipX: false).aim(s)
    let flipped = HandRayMapping(lead: 1.0, flipX: true).aim(s)
    #expect(abs((normal.x - 0.5) + (flipped.x - 0.5)) < 1e-9)   // mirrored across center
    #expect(abs(normal.y - flipped.y) < 1e-9)                    // y unaffected
}

@Test func handRay_flipYMirrorsVertical() {
    let s = handPose(tip: CGPoint(x: 0.5, y: 0.3), mcp: CGPoint(x: 0.5, y: 0.6))
    let normal = HandRayMapping(lead: 1.0, flipY: false).aim(s)
    let flipped = HandRayMapping(lead: 1.0, flipY: true).aim(s)
    #expect(abs((normal.y - 0.5) + (flipped.y - 0.5)) < 1e-9)   // mirrored across center
    #expect(abs(normal.x - flipped.x) < 1e-9)                    // x unaffected
}

@Test func handRay_rayPointsAreKnuckleAndAim() {
    // The overlay helper exposes origin = index MCP (knuckle) and tip = the AIM point (led forward).
    let m = HandRayMapping(lead: 1.5)
    let s = upFinger()
    let ray = m.rayPoints(of: s)
    #expect(ray.origin == s.indexMCP)
    #expect(ray.tip == m.aim(s))
    #expect(ray.tip != s.indexTip)                  // the aim leads past the fingertip
}

@Test func handRay_multiJointAveragingMatchesFallbackForStraightFinger() {
    // With confident PIP/DIP joints laid out straight along MCP→TIP, the averaged direction equals
    // the plain MCP→TIP fallback (no kink), so the aim is identical either way.
    let m = HandRayMapping(lead: 1.5)
    let straightWithRefine = handPose(
        tip: CGPoint(x: 0.7, y: 0.3), mcp: CGPoint(x: 0.5, y: 0.6),
        pip: CGPoint(x: 0.5 + 0.2 / 3, y: 0.6 - 0.3 / 3),
        dip: CGPoint(x: 0.5 + 0.2 * 2 / 3, y: 0.6 - 0.3 * 2 / 3), refineConf: 0.9)
    let fallback = handPose(
        tip: CGPoint(x: 0.7, y: 0.3), mcp: CGPoint(x: 0.5, y: 0.6))   // PIP/DIP conf 0 → fallback
    let a = m.aim(straightWithRefine)
    let b = m.aim(fallback)
    #expect(abs(a.x - b.x) < 1e-9)
    #expect(abs(a.y - b.y) < 1e-9)
}
