import Testing
import CoreGraphics
import CoreVideo
@testable import DirectorSidecar

// SL-1b FaceModelPlugin (acceptance, FR-31). The plugin behind the `.face` picker entry wires
// FaceLandmarks -> the SL-1a pointer-math pipeline -> a PointerOutput in canonical CG top-left
// space (I7). It is a ModelPlugin (id == .face) whose `process` preserves the frame's tCapture
// (the latency anchor) and emits the latest PointerOutput. Real Vision detection is the on-Mac
// gate; here we drive the pipeline DIRECTLY with synthetic FaceSignals (the seam the plugin
// exposes for headless tests) to assert the pointer contract.

private let testScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)

@Test func testFaceModelPluginIdentity() {
    let plugin = FaceModelPlugin(screenProvider: { testScreen })
    #expect(plugin.id == .face)
}

@Test func testProcessPreservesTCapture() {
    // process() runs the Vision path on a synthetic (blank) frame — no face — and returns the
    // frame UNCHANGED so the latency tap still pairs tCapture<->tPhoton (SL-0 contract).
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
    let frame = FrameSample(tCapture: 9.99, pixelBuffer: pb!)
    let plugin = FaceModelPlugin(screenProvider: { testScreen })
    let out = plugin.process(frame)
    #expect(out.tCapture == 9.99)
    #expect(out.pixelBuffer === pb!)
}

@Test func testPipelineProducesLivePointerInScreen() {
    // Drive the pipeline with two synthetic signals: a neutral pose, then a pose offset to the
    // right. The output is a live pointer whose point lies inside the screen rect (I7,
    // canonical CG top-left).
    let plugin = FaceModelPlugin(screenProvider: { testScreen })
    // faceCenter is the (normalized) face-box midpoint Vision supplies — constant here since
    // only the nose moves within a steady head box. Keeping it fixed isolates the nose-offset
    // drive the absolute mode maps from.
    let center = CGPoint(x: 0.5, y: 0.5)
    let neutral = FaceSignal(nose: CGPoint(x: 320, y: 240),
                             leftEye: CGPoint(x: 300, y: 200),
                             rightEye: CGPoint(x: 360, y: 200),
                             faceCenter: center,
                             confidence: 0.9)
    let moved = FaceSignal(nose: CGPoint(x: 326, y: 240),   // nose shifted slightly right
                           leftEye: CGPoint(x: 300, y: 200),
                           rightEye: CGPoint(x: 360, y: 200),
                           faceCenter: center,
                           confidence: 0.9)
    _ = plugin.step(signal: neutral, timestamp: 0.0)
    let out = plugin.step(signal: moved, timestamp: 1.0 / 60.0)
    #expect(out.state == .live)
    // Strictly inside the screen rect (a small offset stays well clear of the clamped edges).
    #expect(out.point.x > testScreen.minX && out.point.x < testScreen.maxX)
    #expect(out.point.y > testScreen.minY && out.point.y < testScreen.maxY)
    // The rightward nose shift moved the cursor right of center (canonical CG top-left).
    #expect(out.point.x > testScreen.midX)
}

@Test func testFreezesOnLowConfidenceNeverOrigin() {
    // A good frame seeds a held point; then a run of low-confidence (lost) frames must FREEZE,
    // holding the last good point — never (0,0) (I6).
    let plugin = FaceModelPlugin(screenProvider: { testScreen })
    let good = FaceSignal(nose: CGPoint(x: 330, y: 240),
                          leftEye: CGPoint(x: 300, y: 200),
                          rightEye: CGPoint(x: 360, y: 200),
                          faceCenter: CGPoint(x: 0.5, y: 0.5),
                          confidence: 0.9)
    let live = plugin.step(signal: good, timestamp: 0.0)
    let heldPoint = live.point

    var last = live
    for i in 1...6 {
        let lowConf = FaceSignal(nose: CGPoint(x: 330, y: 240),
                                 leftEye: CGPoint(x: 300, y: 200),
                                 rightEye: CGPoint(x: 360, y: 200),
                                 confidence: 0.1)   // below face.minConfidence (0.45)
        last = plugin.step(signal: lowConf, timestamp: Double(i) / 60.0)
    }
    #expect(last.state == .frozen)
    #expect(last.point == heldPoint)   // held the last good point
    #expect(last.point != .zero)       // never the origin
}

// MARK: - RC-1: per-model confidence on the output (NFR-10, audit M5)

@Test func testFaceGoodFrameCarriesLiveConfidence() throws {
    // A good frame surfaces the live signal confidence on the output so the HUD can read it
    // (NFR-10). It is passed through verbatim (no remap), exact to the source.
    let plugin = FaceModelPlugin(screenProvider: { testScreen })
    let good = FaceSignal(nose: CGPoint(x: 330, y: 240),
                          leftEye: CGPoint(x: 300, y: 200),
                          rightEye: CGPoint(x: 360, y: 200),
                          faceCenter: CGPoint(x: 0.5, y: 0.5),
                          confidence: 0.83)
    let out = plugin.step(signal: good, timestamp: 0.0)
    let conf = try #require(out.confidence)
    #expect(abs(conf - 0.83) < 1e-9)
}

@Test func testFaceLostFrameHasNoConfidence() {
    // A low-confidence (lost) frame asserts NO confidence — honesty (I10): we don't surface a
    // number we don't have for a frozen/held frame.
    let plugin = FaceModelPlugin(screenProvider: { testScreen })
    let low = FaceSignal(nose: CGPoint(x: 330, y: 240),
                         leftEye: CGPoint(x: 300, y: 200),
                         rightEye: CGPoint(x: 360, y: 200),
                         confidence: 0.1)   // below face.minConfidence (0.45)
    let out = plugin.step(signal: low, timestamp: 0.0)
    #expect(out.confidence == nil)
}
