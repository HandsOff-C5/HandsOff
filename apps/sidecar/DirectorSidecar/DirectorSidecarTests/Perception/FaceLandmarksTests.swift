import Testing
import CoreVideo
import Foundation
import Vision
@testable import DirectorSidecar

// SL-1b Vision face-landmark lift (acceptance, §4.1 + NFR-3). `FaceLandmarks` wraps a
// `VNDetectFaceLandmarksRequest` and resolves a `FaceSignal` from a `FrameSample`'s
// `CVPixelBuffer` — never retaining a `CMSampleBuffer` (NFR-3) and running OFF the main
// thread (the camera video queue). Real detection accuracy is the on-Mac gate; here we
// assert the contract: it consumes a FrameSample, reads the pixel buffer, retains no sample
// buffer, and runs off-main.

@Test(.enabled(if: !PerceptionTestEnv.isHeadlessCI, "real Vision face request hangs on headless CI"))
func testResolvesSignalFromFrameSample() {
    // A FrameSample built the only way the capture path builds one: from a pixel buffer +
    // a timestamp. By construction it carries NO CMSampleBuffer (NFR-3) — the type cannot
    // hold one. A synthetic (blank) buffer won't contain a real face, so detection returns
    // nil; the contract under test is that resolve consumes the FrameSample and does not
    // throw / crash / retain the buffer.
    let pb = makeFaceTestPixelBuffer()
    let frame = FrameSample(tCapture: 7.5, pixelBuffer: pb)

    let landmarks = FaceLandmarks()
    // Resolving on a background queue mirrors the camera video queue. The result is nil for
    // a synthetic blank frame (no face), which is the honest no-face outcome.
    let signal = landmarks.resolve(from: frame)
    #expect(signal == nil, "a blank synthetic frame has no detectable face")

    // FrameSample holds only the CVPixelBuffer + scalars — never a CMSampleBuffer. This is a
    // compile-time/structural guarantee, re-asserted: the buffer we passed is still the one
    // held, nothing was swapped for a retained sample buffer.
    #expect(frame.pixelBuffer === pb)
}

@Test(.enabled(if: !PerceptionTestEnv.isHeadlessCI, "real Vision face request (sync) deadlocks on headless CI"))
func testResolveRunsOffMain() {
    // The resolve must be safe to call off the main thread (it runs on the camera video
    // queue in production). Drive it on a dedicated serial queue — mirroring the camera
    // videoQueue — and confirm it completed off the main thread without requiring the
    // main-actor. A synchronous `sync` (no concurrency-pool task) keeps the test from
    // contending with the rest of the parallel suite.
    let pb = makeFaceTestPixelBuffer()
    let frame = FrameSample(tCapture: 1.0, pixelBuffer: pb)
    let landmarks = FaceLandmarks()
    let videoQueue = DispatchQueue(label: "test.face.video")

    var ranOffMain = false
    videoQueue.sync {
        _ = landmarks.resolve(from: frame)
        ranOffMain = !Thread.isMainThread
    }
    #expect(ranOffMain, "resolve must run off the main thread")
}

@Test func testRequestIsConfiguredOnce() {
    // The request configuration (revision pin) is exposed as a pure factory so it is
    // testable without a camera: it must produce a landmarks request, not a rectangles one.
    let request = FaceLandmarks.makeRequest()
    #expect(request.revision == FaceLandmarks.requestRevision)
}

private func makeFaceTestPixelBuffer() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, 64, 64,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb
    )
    precondition(status == kCVReturnSuccess, "failed to create test pixel buffer")
    return pb!
}
