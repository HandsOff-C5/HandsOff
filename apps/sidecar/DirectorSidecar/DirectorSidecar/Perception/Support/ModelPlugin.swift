import Foundation

// A ModelPlugin is the camera-frame-stream seam: it runs ALONE behind the model picker, taps
// the CameraBus (a `FrameSample` per frame), and renders into the OverlayPanel. The real models
// are now implemented and all RUN behind the picker: Face and Hand are steady camera-stream
// plugins routed through `ModelHost` (this protocol); Calibration is a transient 9-dot capture
// flow that also consumes frames via this protocol but lives outside the fixed host; Voice is a
// transient mic-driven flow (not camera-frame based). The passthrough below remains as the SL-0
// signal-lock baseline (no model in the path) for the raw latency/FPS gate.

/// Identifier for the single active model behind the picker.
public enum LabModelID: String, CaseIterable {
    case none = "None (passthrough)"
    case face = "Face"
    case hand = "Hand"
    case calibration = "Calibration"
    case voice = "Voice"
}

/// A model plugin transforms one `FrameSample` into an output `FrameSample`. Called per
/// frame on the camera video queue. The transform must preserve `tCapture` (it is the
/// motion-to-photon anchor measured at the overlay) unless the model intentionally
/// re-times the frame.
public protocol ModelPlugin {
    var id: LabModelID { get }
    func process(_ frame: FrameSample) -> FrameSample
}

/// The Signal-lock passthrough: returns the frame UNCHANGED (same `tCapture`, same
/// `pixelBuffer`). With no model in the path, the harness measures the raw capture→draw
/// latency that Gate 0 locks before any real model is wired.
public struct PassthroughModel: ModelPlugin {
    public let id: LabModelID = .none
    public init() {}
    public func process(_ frame: FrameSample) -> FrameSample { frame }
}
