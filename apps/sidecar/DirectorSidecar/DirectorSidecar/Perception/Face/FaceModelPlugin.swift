import CoreGraphics
import Foundation

/// The face-pointer capability behind the `.face` picker entry (`FR-31`, `SL-1b`).
///
/// Wires the Vision lift (`FaceLandmarks`) to the SL-1a pure-math pipeline and produces a
/// `PointerOutput` in canonical CG top-left coordinates (`I7`). It is a `ModelPlugin`, so the
/// harness routes one `FrameSample` per frame through `process(_:)`; that returns the frame
/// UNCHANGED (preserving `tCapture`, the latency anchor — SL-0 contract) while emitting the
/// pointer via `onPointer` for the overlay to render. The pure pipeline is also exposed as
/// `step(signal:timestamp:)` so it tests headless with synthetic `FaceSignal`s.
///
/// Pointer mode is **absolute** — the offset-from-neutral maps directly to a screen point, so
/// holding a pose holds the cursor (the mode calibration dwells on; `FaceMapping`). The freeze
/// contract (`I6`) is enforced by `FaceFrameGate`: a low-confidence / no-face frame holds the last
/// good point and reports `.frozen`, never `(0,0)`.
///
/// Not thread-safe by itself; in production `process(_:)` is called serially on the camera
/// video queue (one frame at a time), and `onPointer` is hopped to the main thread by the
/// caller before touching AppKit. This type does no transport (`I5`).
public final class FaceModelPlugin: ModelPlugin {

    public let id: LabModelID = .face

    // Vision lift + SL-1a pipeline components.
    private let landmarks = FaceLandmarks()
    private var mapping: FaceMapping
    private let speed: Double
    private let correctionWeight: Double
    private let filter = FaceFilter()
    private var deadZone = DeadZone()
    private var recenter = Recenter()
    private var dwell = DwellSelector()
    private var gate = FaceFrameGate()

    /// Supplies the screen rect the pointer maps into (canonical CG top-left union). Injected
    /// so the plugin tests headless and the live wiring can pass the real display union.
    private let screenProvider: () -> CGRect

    /// Emitted once per processed frame with the latest pointer (for the overlay). Set by the
    /// integration layer; nil in headless tests that read `step`'s return directly.
    public var onPointer: ((PointerOutput) -> Void)?

    /// The most recent pointer output (for callers that poll rather than subscribe).
    public private(set) var latestOutput: PointerOutput?

    /// The most recent RESOLVED face signal (the raw normalized landmarks actually used — eyes,
    /// nose, face-center), for the on-screen landmark debug overlay. `nil` when the last frame was
    /// lost (no face), so the overlay can clear. Already mirrored if `Params.capture.mirrorX`.
    public private(set) var latestSignal: FaceSignal?

    // Pipeline state across frames.
    private var smoothedVector: CGPoint = .zero
    private var previousVector: CGPoint = .zero
    private var previousTimestamp: Double?
    private var heldPoint: CGPoint?
    /// Edge-mode integrated cursor position (CG top-left). Seeded to screen center on first use.
    private var edgePosition: CGPoint?
    /// EXPERIMENTAL head-pose ray projector (`.ray` mode, branch `experiment/head-ray-gaze`).
    private let headRay = HeadRayMapping()

    public init(
        mode: PointerMode = .absolute,
        speed: Double = 5,
        screenProvider: @escaping () -> CGRect
    ) {
        self.speed = speed
        self.correctionWeight = Params.face.correctionWeight
        self.mapping = FaceMapping(mode: mode, speed: speed)
        self.screenProvider = screenProvider
    }

    /// The active pointer mode (`FR-7`).
    public var pointerMode: PointerMode { mapping.mode }

    /// Switch the pointer mode (`FR-7`, edge ↔ absolute) — the lab toggle. Rebuilds the mapping
    /// (a cheap value type) keeping the same speed / 3D-correction. Edge position re-seeds on the
    /// next frame so a mode switch never snaps to the origin.
    public func setPointerMode(_ mode: PointerMode) {
        mapping = FaceMapping(mode: mode, speed: speed, correctionWeight: correctionWeight)
    }

    /// Request the next observed pose become the new neutral (`FR-8`).
    public func requestRecenter() {
        recenter.requestRecenter()
    }

    /// ModelPlugin entry: resolve a `FaceSignal` from the frame (off-main, NFR-3) and run the
    /// pipeline. A no-face / degenerate frame is a LOST frame — the gate freezes and holds the
    /// last good point (`I6`). Returns the frame UNCHANGED (tCapture preserved).
    public func process(_ frame: FrameSample) -> FrameSample {
        if let signal = landmarks.resolve(from: frame) {
            _ = step(signal: signal, timestamp: frame.tCapture)
        } else {
            _ = stepLost(timestamp: frame.tCapture)
        }
        return frame
    }

    /// Run one pipeline step on a (good) `FaceSignal`. Pure given the injected screen — the
    /// headless test seam. Updates neutral, smooths the control vector, maps to a screen point,
    /// applies the freeze gate, and fires a dwell click if one completes.
    @discardableResult
    public func step(signal: FaceSignal, timestamp: Double) -> PointerOutput {
        // Low-confidence signals are treated as lost (the gate freezes, holds last good).
        guard signal.confidence >= Params.face.minConfidence, signal.eyeDistance > 0 else {
            return stepLost(timestamp: timestamp)
        }
        latestSignal = signal   // resolved (selfie-mirrored) landmarks for the debug overlay; good frame only.

        let dt = frameDelta(timestamp)

        // Control vector vs the current neutral (seeded on the first frame by Recenter).
        let neutral = recenter.neutral ?? signal
        let rawVector = mapping.controlVector(signal: signal, neutral: neutral)

        // Adaptive EMA smoothing of the control vector (D3, FaceFilter).
        let alpha = filter.alpha(rawVector: rawVector, previousVector: previousVector, dt: dt)
        smoothedVector = CGPoint(
            x: filter.blend(previous: smoothedVector.x, raw: rawVector.x, alpha: alpha),
            y: filter.blend(previous: smoothedVector.y, raw: rawVector.y, alpha: alpha)
        )
        previousVector = rawVector

        // Dead-zone / hysteresis decides at-rest, which drives auto neutral-drift.
        let active = deadZone.active(magnitude: magnitude(rawVector))
        recenter.observe(signal, atRest: !active, dt: dt)

        // Map the smoothed offset-from-neutral to a screen point (CG top-left, I7) per mode:
        // edge integrates the GainCurve velocity drive (FR-10); absolute maps position directly.
        let screen = screenProvider()
        let point: CGPoint
        switch mapping.mode {
        case .edge:
            let start = edgePosition ?? CGPoint(x: screen.midX, y: screen.midY)
            let velocity = mapping.edgeVelocity(vector: smoothedVector, speed: speed)
            let moved = CGPoint(x: start.x + CGFloat(velocity.x) * CGFloat(dt),
                                y: start.y + CGFloat(velocity.y) * CGFloat(dt))
            let clamped = CGPoint(
                x: min(max(moved.x, screen.minX), screen.maxX),
                y: min(max(moved.y, screen.minY), screen.maxY))
            edgePosition = clamped
            point = clamped
        case .absolute, .relative:
            point = mapping.absolutePoint(vector: smoothedVector, screen: screen)
        case .ray:
            // EXPERIMENTAL: project the 3D head-pose ray (nose + forehead + pose) onto the screen,
            // relative to the neutral pose (Recenter → center). Uses the raw signal, not the
            // 2D-offset smoothing path.
            point = headRay.project(signal: signal, neutral: neutral, screen: screen)
        }

        // Freeze gate: a good frame adopts this point and reports live. Carry the live signal
        // confidence onto the output for the observability HUD (NFR-10, RC-1).
        var output = gate.accept(signal, heldPoint: point)
        output = PointerOutput(point: output.point, state: output.state,
                               click: output.click, confidence: signal.confidence)
        heldPoint = output.point

        // Dwell-to-click on the held point (FR-13).
        if let click = dwell.update(point: output.point, nowMs: timestamp * 1000.0) {
            output = PointerOutput(point: output.point, state: output.state,
                                   click: click, confidence: signal.confidence)
        }

        emit(output)
        return output
    }

    /// Run one pipeline step for a LOST frame (no face / low confidence): the gate holds the
    /// last good point and reports live (losses ≤ limit) or frozen (losses > limit) — never
    /// `(0,0)` (`I6`). Uses a dummy below-floor signal so the gate counts it as a loss.
    @discardableResult
    private func stepLost(timestamp: Double) -> PointerOutput {
        latestSignal = nil   // no face this frame → clear the debug overlay.
        let held = heldPoint ?? screenCenter()
        let lostSignal = FaceSignal(
            nose: .zero, leftEye: .zero, rightEye: CGPoint(x: 1, y: 0), confidence: 0
        )
        let output = gate.accept(lostSignal, heldPoint: held)
        heldPoint = output.point
        emit(output)
        return output
    }

    private func emit(_ output: PointerOutput) {
        latestOutput = output
        onPointer?(output)
    }

    private func screenCenter() -> CGPoint {
        let s = screenProvider()
        return CGPoint(x: s.midX, y: s.midY)
    }

    /// Clamped frame delta (seconds), matching the salvaged motion guard.
    private func frameDelta(_ timestamp: Double) -> Double {
        defer { previousTimestamp = timestamp }
        guard let previous = previousTimestamp, timestamp > previous else { return 1.0 / 30.0 }
        return min(max(timestamp - previous, 1.0 / 120.0), 0.25)
    }

    private func magnitude(_ p: CGPoint) -> Double { Double(hypot(p.x, p.y)) }
}
