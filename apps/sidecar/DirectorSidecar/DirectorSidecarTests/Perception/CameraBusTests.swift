import Testing
import CoreVideo
import QuartzCore
@testable import DirectorSidecar

// SL-0 input-path pure logic. The AVFoundation session can't run headless, so the
// *decisions* are extracted into pure types tested here with synthetic inputs:
//   • CameraFormatSelector — picks the highest-frame-rate native-420 format.
//   • FreezeTracker — freeze-on-dropout (I6): hold last-good, never snap to default.

// MARK: - Format selection (FR-3)

@Test func test_selectsHighestFrameRate_andNeverRetainsBuffer() {
    // Stub the device's format list: a 30fps BGRA, a 60fps 420v, a 60fps 420f.
    let bgra30 = FormatInfo(
        maxFrameRate: 30,
        pixelFormat: kCVPixelFormatType_32BGRA,
        width: 1280, height: 720
    )
    let v420_60 = FormatInfo(
        maxFrameRate: 60,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,  // 420v
        width: 1280, height: 720
    )
    let f420_60 = FormatInfo(
        maxFrameRate: 60,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,   // 420f
        width: 1280, height: 720
    )

    let chosen = CameraFormatSelector.selectHighestFrameRate(from: [bgra30, v420_60, f420_60])
    #expect(chosen != nil)
    // Highest max frame rate wins (60 over 30); tie-break prefers native 420 over BGRA.
    #expect(chosen?.maxFrameRate == 60)
    #expect(chosen?.isNative420 == true)
    // Among the two 60fps native-420 formats the video-range (420v) is preferred first.
    #expect(chosen?.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

    // neverRetainsBuffer half: the capture path builds a FrameSample from a CVPixelBuffer
    // ONLY — the CMSampleBuffer is never handed to this helper, so it cannot escape. We
    // exercise that helper here: it takes a CVPixelBuffer + tCapture and yields a
    // FrameSample whose pixelBuffer is the very buffer passed in (identity preserved),
    // proving the sample buffer is not part of the data path. (See CameraBus.captureOutput,
    // where CMSampleBufferGetImageBuffer is the only thing extracted and the
    // CMSampleBuffer parameter never escapes the callback scope — NFR-3.)
    let pb = makeTestPixelBuffer()
    let sample = makeFrameSample(pixelBuffer: pb, tCapture: 1.5)
    #expect(sample.tCapture == 1.5)
    #expect(sample.pixelBuffer === pb)
    #expect(sample.tPhoton == nil)
}

@Test func test_selector_emptyList_returnsNil() {
    #expect(CameraFormatSelector.selectHighestFrameRate(from: []) == nil)
}

@Test func test_selector_tieBreak_prefersLargerDimensions_amongSameFormat() {
    // Same fps + same pixel format → larger dimensions wins (last tie-break).
    let small = FormatInfo(
        maxFrameRate: 60,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        width: 640, height: 480
    )
    let large = FormatInfo(
        maxFrameRate: 60,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        width: 1920, height: 1080
    )
    let chosen = CameraFormatSelector.selectHighestFrameRate(from: [small, large])
    #expect(chosen?.width == 1920)
    #expect(chosen?.height == 1080)
}

// MARK: - Device selection (highest-fps device, FR-3 follow-up)

@Test func test_selectsHighestFrameRateDevice() {
    // The built-in FaceTime HD camera caps at 30 fps; the iPhone Continuity Camera offers
    // 60 fps. The selector must pick the 60-fps device so the frame-bound latency halves.
    let builtin30 = DeviceInfo(
        uniqueID: "builtin", name: "FaceTime HD Camera", maxFrameRate: 30, isBuiltIn: true
    )
    let iPhone60 = DeviceInfo(
        uniqueID: "iphone", name: "iPhone Camera", maxFrameRate: 60, isBuiltIn: false
    )
    let chosen = CameraDeviceSelector.selectHighestFrameRate(from: [builtin30, iPhone60])
    #expect(chosen?.uniqueID == "iphone")
    #expect(chosen?.maxFrameRate == 60)
}

@Test func test_deviceTieBreakPrefersBuiltIn() {
    // Equal frame rates → prefer the built-in device for stability (no Continuity wakeup
    // races, no cable/wifi dropouts).
    let builtin60 = DeviceInfo(
        uniqueID: "builtin", name: "FaceTime HD Camera", maxFrameRate: 60, isBuiltIn: true
    )
    let external60 = DeviceInfo(
        uniqueID: "external", name: "External Webcam", maxFrameRate: 60, isBuiltIn: false
    )
    // Order-independent: built-in wins whether it's first or last in the list.
    #expect(CameraDeviceSelector.selectHighestFrameRate(from: [builtin60, external60])?.isBuiltIn == true)
    #expect(CameraDeviceSelector.selectHighestFrameRate(from: [external60, builtin60])?.isBuiltIn == true)
}

@Test func test_builtInPreferred_picksBuiltInOverFasterIPhone() {
    // DEFAULT selection: the laptop's built-in camera is chosen even when a 60-fps iPhone is
    // present (don't grab the Continuity Camera unless explicitly asked).
    let builtin30 = DeviceInfo(
        uniqueID: "builtin", name: "FaceTime HD Camera", maxFrameRate: 30, isBuiltIn: true
    )
    let iPhone60 = DeviceInfo(
        uniqueID: "iphone", name: "iPhone Camera", maxFrameRate: 60, isBuiltIn: false
    )
    let chosen = CameraDeviceSelector.selectBuiltInPreferred(from: [iPhone60, builtin30])
    #expect(chosen?.uniqueID == "builtin")
    #expect(chosen?.isBuiltIn == true)
}

@Test func test_builtInPreferred_fallsBackToHighestFpsWhenNoBuiltIn() {
    // No built-in present (e.g. a desktop) → fall back to the highest-fps device.
    let webcam30 = DeviceInfo(uniqueID: "w30", name: "Webcam A", maxFrameRate: 30, isBuiltIn: false)
    let webcam60 = DeviceInfo(uniqueID: "w60", name: "Webcam B", maxFrameRate: 60, isBuiltIn: false)
    let chosen = CameraDeviceSelector.selectBuiltInPreferred(from: [webcam30, webcam60])
    #expect(chosen?.uniqueID == "w60")
}

@Test func test_builtInPreferred_emptyList_returnsNil() {
    #expect(CameraDeviceSelector.selectBuiltInPreferred(from: []) == nil)
}

@Test func test_deviceSelector_emptyList_returnsNil() {
    #expect(CameraDeviceSelector.selectHighestFrameRate(from: []) == nil)
}

// MARK: - Freeze on dropout (I6, FR-5) — reusable by SL-1/SL-3

@Test func test_freezesAfterLostFrameLimit() {
    // lostFrameLimit good values, then lostFrameLimit+1 consecutive losses.
    let limit = Params.capture.lostFrameLimit
    var tracker = FreezeTracker<Int>()

    // Feed several good values; state stays .live, value tracks the latest good.
    tracker.update(.good(7))
    #expect(tracker.state == .live)
    #expect(tracker.value == 7)
    tracker.update(.good(11))
    #expect(tracker.state == .live)
    #expect(tracker.value == 11)
    let lastGood = 11

    // Negative control: a single isolated loss (≤ limit) does NOT freeze; holds last good.
    tracker.update(.lost)
    #expect(tracker.state == .live)
    #expect(tracker.value == lastGood)  // held, never a zero/default substitution.

    // Recover, then drive the consecutive-loss run to exactly the limit: still live.
    tracker.update(.good(11))
    for _ in 0..<limit {
        tracker.update(.lost)
        #expect(tracker.state == .live)        // losses ≤ limit pass through.
        #expect(tracker.value == lastGood)     // last-good held throughout.
    }
    // One more loss EXCEEDS the limit → frozen, still holding the last good value.
    tracker.update(.lost)
    #expect(tracker.state == .frozen)
    #expect(tracker.value == lastGood)         // NEVER snaps to 0/default (I6).
}

@Test func test_freeze_recoversToLive_onGoodFrame() {
    let limit = Params.capture.lostFrameLimit
    var tracker = FreezeTracker<Int>()
    tracker.update(.good(5))
    for _ in 0...limit { tracker.update(.lost) }  // limit+1 losses → frozen.
    #expect(tracker.state == .frozen)
    #expect(tracker.value == 5)
    // A good frame recovers to live and updates the held value.
    tracker.update(.good(9))
    #expect(tracker.state == .live)
    #expect(tracker.value == 9)
}

// MARK: - Test helpers

/// Build a tiny CVPixelBuffer for identity assertions (no camera needed).
private func makeTestPixelBuffer() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, 16, 16,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb
    )
    precondition(status == kCVReturnSuccess, "failed to create test pixel buffer")
    return pb!
}
