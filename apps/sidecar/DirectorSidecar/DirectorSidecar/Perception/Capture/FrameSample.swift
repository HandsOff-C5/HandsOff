import CoreVideo
import QuartzCore

/// One captured camera frame, handed from `CameraBus` to the model/overlay path.
///
/// **NFR-3 invariant:** a `FrameSample` must NEVER retain a `CMSampleBuffer`. Capturing
/// a `CMSampleBuffer` past the delegate callback starves AVFoundation's buffer pool and
/// stalls capture. We copy/retain only the Vision-ready `CVPixelBuffer` and the host-clock
/// timestamps — never the sample buffer itself.
///
/// Latency is a motion-to-photon proxy: `tPhoton − tCapture`. `tCapture` is the sample
/// buffer's presentation timestamp (PTS) — the capture-side clock, NOT frame-delivery time
/// — so the capture-pipeline cost is included; `tPhoton` is stamped by the overlay at
/// render-commit (left `nil` until then). The PTS is on the host-time clock
/// (`CMClockGetHostTimeClock`), the same base as `CACurrentMediaTime()`, so the two are
/// directly comparable. This proxy cannot include sensor-exposure or display-emission
/// latency — the authoritative end-to-end is the external 240-fps glass-to-glass check.
public struct FrameSample {
    /// Host-clock capture timestamp (sample-buffer PTS), in `CACurrentMediaTime()` units (seconds).
    public let tCapture: Double

    /// The Vision-ready image buffer. Retaining a `CVPixelBuffer` is fine (NFR-3 only
    /// forbids retaining a `CMSampleBuffer`).
    public let pixelBuffer: CVPixelBuffer

    /// Host-clock draw timestamp, stamped by the overlay at present time. `nil` until the
    /// frame is drawn. Latency proxy = `tPhoton − tCapture`.
    public var tPhoton: Double?

    public init(tCapture: Double, pixelBuffer: CVPixelBuffer, tPhoton: Double? = nil) {
        self.tCapture = tCapture
        self.pixelBuffer = pixelBuffer
        self.tPhoton = tPhoton
    }

    /// Motion-to-photon latency in milliseconds, or `nil` if the frame has not been drawn.
    public var latencyMs: Double? {
        guard let tPhoton else { return nil }
        return (tPhoton - tCapture) * 1000.0
    }
}
