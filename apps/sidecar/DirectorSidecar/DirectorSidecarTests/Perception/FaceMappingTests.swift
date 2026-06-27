import Testing
import CoreGraphics
@testable import DirectorSidecar

// Pointer modes (FR-7) + 3D fine-correction cap (FR-11). All pointer output is canonical
// CoreGraphics TOP-LEFT (I7): y grows DOWN, so a positive (upward) head-control vector maps
// to a SMALLER screen y.

// A neutral face looking straight ahead at frame center.
private func neutral() -> FaceSignal {
    FaceSignal(
        nose: CGPoint(x: 0, y: 0),
        leftEye: CGPoint(x: -30, y: 0),
        rightEye: CGPoint(x: 30, y: 0),   // eyeDistance = 60, eyeMidpoint = (0,0)
        faceCenter: CGPoint(x: 0, y: 0),
        faceBoxWidth: 1.0,
        yaw: 0, pitch: 0,
        confidence: 1.0
    )
}

// A single screen, CG top-left, 1000×800 at the origin.
private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

@Test func testAbsoluteMode() {
    // Absolute mode maps offset-from-neutral DIRECTLY to a screen point (holding a pose holds
    // the cursor). Move the nose right (+0.1 in normalized units) and down (−0.1, screen-down
    // is image-down). controlVector.x = noseX·0.75 = 0.075; .y = noseY·0.75.
    // Nose at (6, -6): noseOffset = (6/60, -6/60) = (0.1, -0.1).
    let sig = FaceSignal(
        nose: CGPoint(x: 6, y: -6),
        leftEye: CGPoint(x: -30, y: 0),
        rightEye: CGPoint(x: 30, y: 0),
        faceCenter: CGPoint(x: 0, y: 0),
        yaw: 0, pitch: 0, confidence: 1.0
    )
    let mapping = FaceMapping(mode: .absolute, speed: 5)
    let v = mapping.controlVector(signal: sig, neutral: neutral())
    // x = 0.1·0.75 = 0.075 ; y = -0.1·0.75 = -0.075 (yaw/pitch = 0, center = 0).
    #expect(abs(v.x - 0.075) < 1e-9)
    #expect(abs(v.y - (-0.075)) < 1e-9)

    // absolutePoint: gain = speed·0.45 = 2.25 ; nx = clamp(0.5 + 0.075·2.25) = 0.66875.
    // CG top-left: ny flips the up-positive control → ny = clamp(0.5 - v.y·vGain). Here v.y < 0
    // (cursor DOWNWARD), so the asymmetric down-gain applies: vGain = gain·verticalDownGain =
    // 2.25·1.8 = 4.05 (Params.face.verticalDownGain fixes the "can't reach the bottom" asymmetry).
    //   ny = clamp(0.5 - (-0.075)·4.05) = 0.80375.
    // x is unaffected by the down-gain (horizontal stays symmetric).
    let p = mapping.absolutePoint(vector: v, screen: screen)
    #expect(abs(p.x - 668.75) < 1e-6)   // 0.66875 · 1000
    #expect(abs(p.y - 643.0) < 1e-6)    // 0.80375 · 800
}

@Test func testEdgeMode() {
    // Edge mode shares the control-vector formula with absolute; the velocity integration is
    // the dead-zone/gain stage (tested separately). Here we pin the control vector: a pure
    // nose move with no center motion. Nose (12,0) → noseOffset.x = 0.2 → v.x = 0.2·0.75 = 0.15.
    let sig = FaceSignal(
        nose: CGPoint(x: 12, y: 0),
        leftEye: CGPoint(x: -30, y: 0),
        rightEye: CGPoint(x: 30, y: 0),
        faceCenter: CGPoint(x: 0, y: 0),
        yaw: 0, pitch: 0, confidence: 1.0
    )
    let mapping = FaceMapping(mode: .edge, speed: 5)
    let v = mapping.controlVector(signal: sig, neutral: neutral())
    #expect(abs(v.x - 0.15) < 1e-9)
    #expect(abs(v.y - 0.0) < 1e-9)
}

@Test func testRelativeMode() {
    // Relative mode: v.x = centerX/scale + noseX·0.25, scale = max(neutral.faceBoxWidth, 0.1).
    // Move the face center right by 0.2 (faceCenter.x = 0.2) with neutral faceBoxWidth = 1.0,
    // and nose offset 0.2 → v.x = 0.2/1.0 + 0.2·0.25 = 0.2 + 0.05 = 0.25.
    let sig = FaceSignal(
        nose: CGPoint(x: 12, y: 0),          // noseOffset.x = 0.2
        leftEye: CGPoint(x: -30, y: 0),
        rightEye: CGPoint(x: 30, y: 0),
        faceCenter: CGPoint(x: 0.2, y: 0),
        faceBoxWidth: 1.0,
        yaw: 0, pitch: 0, confidence: 1.0
    )
    let mapping = FaceMapping(mode: .relative, speed: 5)
    let v = mapping.controlVector(signal: sig, neutral: neutral())
    #expect(abs(v.x - 0.25) < 1e-9)
    #expect(abs(v.y - 0.0) < 1e-9)
}

@Test func testCorrectionWeightCapped() {
    // FR-11: the yaw/pitch 3D contribution is capped at face.correctionWeight (DEMOTED, not
    // 0.55). With weight 0 the 3D term is EXACTLY zero → pure-2D mapping.
    let sig = FaceSignal(
        nose: CGPoint(x: 6, y: 0),           // noseOffset.x = 0.1
        leftEye: CGPoint(x: -30, y: 0),
        rightEye: CGPoint(x: 30, y: 0),
        faceCenter: CGPoint(x: 0, y: 0),
        yaw: 1.0, pitch: 0, confidence: 1.0  // a full radian of yaw
    )

    // weight 0 → pure 2D: v.x = noseX·0.75 = 0.075, the yaw term contributes nothing.
    let pure2D = FaceMapping(mode: .edge, speed: 5, correctionWeight: 0)
    let v0 = pure2D.controlVector(signal: sig, neutral: neutral())
    #expect(abs(v0.x - 0.075) < 1e-12)   // EXACTLY the 2D term, no 3D leak

    // weight 0.15 → the yaw contribution is yaw·weight = 1.0·0.15, and is <= correctionWeight.
    let capped = FaceMapping(mode: .edge, speed: 5, correctionWeight: 0.15)
    let v1 = capped.controlVector(signal: sig, neutral: neutral())
    let yawContribution = v1.x - v0.x
    #expect(yawContribution <= 0.15 + 1e-12)        // contribution capped at correctionWeight
    #expect(abs(yawContribution - 0.15) < 1e-9)     // and equals yaw(1.0)·weight here
}
