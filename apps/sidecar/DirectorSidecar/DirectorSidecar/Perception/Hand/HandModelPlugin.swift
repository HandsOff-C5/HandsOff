import CoreGraphics
import Foundation

/// The hand-pointer capability behind the `.hand` picker entry (`FR-31`, `SL-3`).
///
/// Wires the Vision hand-pose lift (`HandModel`) to the SL-3 pure-math pipeline and produces a
/// `PointerOutput` in canonical CG top-left coordinates (`I7`). It is a `ModelPlugin`, so the
/// harness routes one `FrameSample` per frame through `process(_:)`; that returns the frame
/// UNCHANGED (preserving `tCapture`, the latency anchor — SL-0 contract) while emitting the
/// pointer via `onPointer` for the overlay to render. The pure pipeline is exposed as
/// `step(signal:timestamp:)` so it tests headless with synthetic `HandSignal`s.
///
/// Pipeline per good frame: index-MCP validity gate (`IndexTip.isValid`) → `.indexTip` cursor
/// (NOT averaged, `IndexTip.cursor`) → shared 1€ smoothing + confidence-freeze (`HandFilter`) →
/// fingertip → screen. The fingertip→screen step uses the per-display **SL-2 calibration fit**
/// when one is installed (`setCalibration`, `RB-3`: `fit.apply` → screen-normalized `[0,1]` →
/// screen rect), and otherwise falls back to the uncalibrated `ActiveRegion` (inset stretch +
/// CD-gain + identity homography). A no-hand or low-confidence frame holds the last good point
/// and reports `.frozen`, never `(0,0)` (`I6`).
///
/// Not thread-safe by itself; in production `process(_:)` is called serially on the camera video
/// queue, and `onPointer` is hopped to the main thread by the caller. This type does no
/// transport (`I5`).
public final class HandModelPlugin: ModelPlugin {

    public let id: LabModelID = .hand

    private let model = HandModel()
    private let region: ActiveRegion
    private let filter: HandFilter

    /// EXPERIMENTAL index-finger RAY pointer (branch `experiment/head-ray-gaze`), gated OFF by
    /// default via `HANDSOFF_HAND_RAY` (== "1"). When OFF, the pointer path is the SL-3 fingertip
    /// mapping verbatim (all existing hand tests stay green). When ON, the index finger is treated
    /// as a laser AIMED at the screen (ABSOLUTE "point-at-the-spot", `HandRayMapping.aim`): the
    /// fingertip is led forward along the pointing direction and then run through the SAME active-
    /// region / calibration mapping as the 2D fingertip, so left/right stays consistent and the
    /// SL-2 calibration still applies. No neutral and no Recenter.
    public let rayEnabled: Bool
    private let handRay = HandRayMapping()

    /// The per-display SL-2 calibration map for the HAND target (`FR-17`, `RB-3`), reconstructed by
    /// the integration layer from the persisted `CalibrationProfile`. When set, the (1€-smoothed)
    /// fingertip is mapped through `fit.apply(...)` — which yields a SCREEN-NORMALIZED `[0,1]` point
    /// (the RB-1b fit→screen contract) — then clamped and placed into the screen rect, BYPASSING the
    /// uncalibrated `ActiveRegion` inset/identity stretch. `nil` (the default) keeps the uncalibrated
    /// active-region path unchanged. CD-gain sensitivity (`FR-18`) is a property of the uncalibrated
    /// active region only: the fit IS the mapping (it already encodes the per-display geometry), so
    /// the calibrated path does not re-apply CD-gain on top of it.
    public var calibration: CalibrationFit?

    /// Supplies the screen rect the pointer maps into (canonical CG top-left union). Injected so
    /// the plugin tests headless and the live wiring passes the real display union.
    private let screenProvider: () -> CGRect

    /// Emitted once per processed frame with the latest pointer (for the overlay). Set by the
    /// integration layer; nil in headless tests that read `step`'s return directly.
    public var onPointer: ((PointerOutput) -> Void)?

    /// The most recent pointer output (for callers that poll rather than subscribe).
    public private(set) var latestOutput: PointerOutput?

    /// The most recent RESOLVED hand signal, for the landmark debug overlay. The cursor is driven
    /// ONLY by `indexTip` (the `.indexTip` cursor — MCP is validity-only, middleTip a control), so
    /// the overlay draws that one point. `nil` when the last frame was lost. Mirrored if enabled.
    public private(set) var latestSignal: HandSignal?

    public init(
        homography: PerceptionHomography = .identity,
        inset: Double = Params.hand.activeRegionInset,
        calibration: CalibrationFit? = nil,
        rayEnabled: Bool = HandRayMapping.envBool("HANDSOFF_HAND_RAY", false),
        screenProvider: @escaping () -> CGRect
    ) {
        self.region = ActiveRegion(inset: inset, homography: homography)
        self.filter = HandFilter()
        self.calibration = calibration
        self.rayEnabled = rayEnabled
        self.screenProvider = screenProvider
    }

    /// The finger-ray overlay endpoints (`HANDSOFF_HAND_RAY`): the knuckle (index MCP, ray origin)
    /// and the AIM point where the laser lands (the fingertip led forward). `nil` when no current
    /// signal. Lets the lab draw the laser without reaching into the private mapping.
    public var rayOverlayPoints: (knuckle: CGPoint, aim: CGPoint)? {
        guard let s = latestSignal else { return nil }
        let p = handRay.rayPoints(of: s)
        return (knuckle: p.origin, aim: p.tip)
    }

    /// Install (or clear) the per-display HAND calibration fit (`RB-3`). Passing `nil` reverts to the
    /// uncalibrated active-region path. The integration layer calls this when the user activates the
    /// Hand pointer, after loading the display's profile and reconstructing it via `calibrationFit()`.
    public func setCalibration(_ fit: CalibrationFit?) {
        self.calibration = fit
    }

    /// ModelPlugin entry: resolve a `HandSignal` from the frame (off-main, NFR-3) and run the
    /// pipeline. A no-hand frame is a LOST frame — the filter freezes and holds the last good
    /// point (`I6`). Returns the frame UNCHANGED (tCapture preserved).
    public func process(_ frame: FrameSample) -> FrameSample {
        if let signal = model.resolve(from: frame) {
            _ = step(signal: signal, timestamp: frame.tCapture)
        } else {
            _ = stepLost(timestamp: frame.tCapture)
        }
        return frame
    }

    /// Run one pipeline step on a `HandSignal`. Pure given the injected screen — the headless
    /// test seam. An invalid (low index-MCP) reading is treated as lost; otherwise the index
    /// fingertip is mapped through the active region and smoothed, with the freeze gate holding
    /// on low fingertip confidence.
    @discardableResult
    public func step(signal: HandSignal, timestamp: Double) -> PointerOutput {
        guard IndexTip.isValid(signal) else { return stepLost(timestamp: timestamp) }
        latestSignal = signal   // resolved (selfie-mirrored) joints for the debug overlay; valid frame only.
        if rayEnabled { return stepRay(signal: signal, timestamp: timestamp) }
        // FR-18 / §5d-5: smooth the FINGERTIP (normalized frame space) with the 1€ filter BEFORE
        // mapping, and gate the freeze here; then map the smoothed fingertip through the active
        // region (CD-gain + homography) to a screen point. Filtering pre-map keeps the cutoff in
        // fingertip space (independent of the region→screen magnification).
        let tip = IndexTip.cursor(signal)
        let smoothed = filter.update(
            point: tip, confidence: signal.indexTipConfidence, tMs: timestamp * 1000.0)
        let screenPoint = mapToScreen(fingertip: smoothed.point)
        // Surface the live index-fingertip confidence on the output for the HUD (NFR-10, RC-1);
        // a frozen frame is HELD, not live, so it carries no confidence (I10, honesty).
        let confidence: Double? = smoothed.state == .live ? signal.indexTipConfidence : nil
        let output = PointerOutput(point: screenPoint, state: smoothed.state, confidence: confidence)
        emit(output)
        return output
    }

    /// Run one ray-mode pipeline step (EXPERIMENTAL, `HANDSOFF_HAND_RAY`). ABSOLUTE point-at-the-spot:
    /// compute the finger's AIM point (fingertip led forward along the pointing direction, normalized
    /// top-left), smooth THAT in fingertip space with the 1€ filter, then run it through the SAME
    /// `mapToScreen` the 2D path uses — so the active-region / SL-2 calibration mapping is shared and
    /// left/right stays consistent with the proven 2D mode. Never `(0,0)` (`I6`); carries the live
    /// fingertip confidence on a live frame (RC-1).
    @discardableResult
    private func stepRay(signal: HandSignal, timestamp: Double) -> PointerOutput {
        let aim = handRay.aim(signal)
        let smoothed = filter.update(
            point: aim, confidence: signal.indexTipConfidence, tMs: timestamp * 1000.0)
        let screenPoint = mapToScreen(fingertip: smoothed.point)
        let confidence: Double? = smoothed.state == .live ? signal.indexTipConfidence : nil
        let output = PointerOutput(point: screenPoint, state: smoothed.state, confidence: confidence)
        emit(output)
        return output
    }

    /// Run one pipeline step for a LOST frame (no hand / invalid reading): the filter holds the
    /// last good FINGERTIP and reports live (losses ≤ limit) or frozen (losses > limit); the held
    /// fingertip is re-mapped to a screen point — never `(0,0)` (`I6`). Before any good frame the
    /// fallback is the region center (`0.5,0.5`) → screen center, not the origin.
    @discardableResult
    private func stepLost(timestamp: Double) -> PointerOutput {
        latestSignal = nil   // no hand this frame → clear the debug overlay.
        let smoothed = filter.update(
            point: CGPoint(x: 0.5, y: 0.5), confidence: 0, tMs: timestamp * 1000.0)
        let screenPoint = mapToScreen(fingertip: smoothed.point)
        let output = PointerOutput(point: screenPoint, state: smoothed.state)
        emit(output)
        return output
    }

    /// Map a (1€-smoothed) normalized fingertip to a screen point, choosing the path: when a
    /// `CalibrationFit` is installed (`RB-3`) the fit drives the mapping (raw fingertip → screen-
    /// normalized `[0,1]` per the RB-1b contract → clamp → screen rect), BYPASSING the uncalibrated
    /// inset/identity stretch; otherwise the uncalibrated `ActiveRegion` path is used unchanged. This
    /// sits AFTER the 1€ filter (RA-1: smooth in fingertip space before magnifying to the screen).
    private func mapToScreen(fingertip: CGPoint) -> CGPoint {
        let screen = screenProvider()
        guard let fit = calibration else {
            return region.map(fingertip: fingertip, screen: screen)
        }
        guard screen.width > 0, screen.height > 0 else {
            return CGPoint(x: screen.midX, y: screen.midY)
        }
        let n = fit.apply(SIMD2<Double>(Double(fingertip.x), Double(fingertip.y)))
        let nx = max(0.0, min(1.0, n.x))
        let ny = max(0.0, min(1.0, n.y))
        return CGPoint(
            x: screen.minX + CGFloat(nx) * screen.width,
            y: screen.minY + CGFloat(ny) * screen.height
        )
    }

    private func emit(_ output: PointerOutput) {
        latestOutput = output
        onPointer?(output)
    }
}
