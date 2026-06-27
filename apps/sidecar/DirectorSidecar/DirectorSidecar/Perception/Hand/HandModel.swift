import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Vision hand-pose lift (`SL-3`, `FR-14`, `I5`, `NFR-3`).
///
/// Mirrors the `FaceLandmarks` pattern: turn a captured frame's pixel buffer into a `HandSignal`
/// (index fingertip + MCP + middle tip, with confidences), in-process, no transport (`I5`). The
/// request is a `VNDetectHumanHandPoseRequest` pinned to ONE hand (`maximumHandCount = 1`,
/// FR-14) and a fixed revision (deterministic across OS updates).
///
/// **NFR-3:** `resolve(from:)` reads ONLY `frame.pixelBuffer` (a `FrameSample` never holds a
/// `CMSampleBuffer`); Vision reads it through a `VNImageRequestHandler` and retains nothing past
/// the call. **Off-main:** `perform` is synchronous and thread-agnostic — invoked on the camera
/// video queue in production, never the main thread.
///
/// **Coordinate convention (`I7`):** Vision hand-pose normalized points use a BOTTOM-left origin
/// (y grows up). `signal(from:)` flips y to canonical TOP-left (`y' = 1 − y`) at the boundary so
/// every downstream component (`ActiveRegion`, the screen mapping) speaks one convention. Real
/// detection accuracy is the on-Mac SL-3 gate; a blank synthetic frame correctly yields `nil`.
public struct HandModel {

    /// The hand-pose request revision we pin (deterministic). Revision 1 is the broadly
    /// available baseline; the lift degrades to `nil` (a lost frame) if it is unavailable.
    ///
    /// **Why the legacy `VNDetectHumanHandPoseRequest` (audit m2 — DEFERRED to SL-3 on-Mac gate):**
    /// macOS 26 ships the modern Swift-native `DetectHumanHandPoseRequest` (FR-14), but ALL of its
    /// `perform(on:)` overloads are `async throws` (`Vision.ImageProcessingRequest`) — there is no
    /// synchronous variant on the macOS-26 SDK (verified against the Vision `.swiftinterface`). Our
    /// `resolve(from:)` is a SYNCHRONOUS per-frame lift on the camera video queue feeding a
    /// synchronous freeze pipeline (NFR-3 / I6 / I9); adopting the modern API as primary would force
    /// either an unbounded async wait that blocks the video queue or an async refactor of the hot
    /// path — neither validatable headless. So the legacy synchronous request stays PRIMARY (correct
    /// and NOT removed on 26). The modern async path is the on-Mac upgrade: it needs real-hand
    /// validation plus an async hot-path restructure, tracked for the SL-3 gate.
    public static let requestRevision = VNDetectHumanHandPoseRequestRevision1

    /// Image orientation for Vision: GEOMETRY ONLY (`.up`). The data-output buffer is delivered
    /// upright and UN-mirrored (the data connection sets no mirroring — only the PREVIEW is
    /// mirrored), so the orientation must NOT carry a horizontal flip. The selfie mirror is owned
    /// solely by `Params.capture.mirrorX` (applied as `mirroredX()` in `resolve`, paired with the
    /// preview's `isVideoMirrored`). Using `.upMirrored` here was a second, unpaired flip that put
    /// the landmark on the opposite side from the preview (double-mirror bug).
    private let orientation: CGImagePropertyOrientation

    public init(orientation: CGImagePropertyOrientation = .up) {
        self.orientation = orientation
    }

    /// Build the hand-pose request — ONE hand, revision pinned (`FR-14`). Pure factory so it is
    /// testable without a camera (the request is reusable; results are read after `perform`).
    ///
    /// **FR-25 — DEFERRED:** the higher-accuracy calibration mode (13–16 capture points / 3rd-order
    /// polynomial fit) is not implemented. Its natural home is the calibration fit (`Models/
    /// Calibration/Fit.swift`), not the hand lift; this lift emits the same `HandSignal` regardless
    /// of fit order. Tracked for a later slice.
    public static func makeRequest() -> VNDetectHumanHandPoseRequest {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        request.revision = requestRevision
        return request
    }

    /// Resolve a `HandSignal` from one captured frame, or `nil` if no usable hand is found.
    ///
    /// Reads ONLY `frame.pixelBuffer` (NFR-3). Runs synchronously on the calling queue (the
    /// camera video queue in production — off-main). Returns `nil` for a no-hand / degenerate
    /// frame so the freeze gate (`HandFilter`) treats it as a lost frame (`I6`, never `(0,0)`).
    public func resolve(from frame: FrameSample) -> HandSignal? {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        let request = Self.makeRequest()
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first
        else { return nil }
        guard let signal = Self.signal(from: observation) else { return nil }
        // Mirror the live signal so the pointer follows the user (selfie convention, on-Mac knob);
        // applied here so the calibration capture (which also calls resolve) stays consistent.
        return Params.capture.mirrorX ? signal.mirroredX() : signal
    }

    /// Build a `HandSignal` from a hand-pose observation, or `nil` if the index joints are
    /// missing. Pure — testable from a synthetic observation. The cursor joint (`.indexTip`) and
    /// the validity joint (`.indexMCP`) are required; everything else is best-effort: `.middleTip`
    /// (the averaging negative-control) defaults to the index tip, and the EXPERIMENTAL finger-ray
    /// refinement joints (`.indexPIP`, `.indexDIP`, `.littleMCP`) are passed through when Vision
    /// resolves them and left to the `HandSignal` init's geometric defaults (confidence `0`)
    /// otherwise — a weak refinement joint never voids the frame. Vision's bottom-left origin is
    /// flipped to canonical CG top-left here (`I7`).
    static func signal(from observation: VNHumanHandPoseObservation) -> HandSignal? {
        guard let tip = try? observation.recognizedPoint(.indexTip),
              let mcp = try? observation.recognizedPoint(.indexMCP)
        else { return nil }
        let mid = try? observation.recognizedPoint(.middleTip)
        let pip = try? observation.recognizedPoint(.indexPIP)
        let dip = try? observation.recognizedPoint(.indexDIP)
        let little = try? observation.recognizedPoint(.littleMCP)

        // Flip Vision's bottom-left normalized origin to canonical CG top-left (I7).
        func topLeft(_ p: VNRecognizedPoint) -> CGPoint {
            CGPoint(x: p.location.x, y: 1 - p.location.y)
        }

        return HandSignal(
            indexTip: topLeft(tip),
            indexMCP: topLeft(mcp),
            middleTip: mid.map(topLeft),
            indexPIP: pip.map(topLeft),
            indexDIP: dip.map(topLeft),
            littleMCP: little.map(topLeft),
            indexTipConfidence: Double(tip.confidence),
            indexMCPConfidence: Double(mcp.confidence),
            indexPIPConfidence: pip.map { Double($0.confidence) } ?? 0,
            indexDIPConfidence: dip.map { Double($0.confidence) } ?? 0,
            littleMCPConfidence: little.map { Double($0.confidence) } ?? 0
        )
    }
}
