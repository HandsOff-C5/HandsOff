// PointingEventAdapter — the perception emission seam (RESEARCH_CONVERGENCE §7; MIGRATION §8).
//
// Our hand/face pointer plugins already expose `step(…)→PointerOutput` (a CG top-left point + a
// live/frozen state + a confidence). This adapter wraps that output into the shared Envelope
// `PointingEvent` the concurrent PerceptionBus rings and the S4 Aligner consume — tagging the
// modality source (`.hand_pose` / `.face_gaze`), stamping `tSrc` from the ONE monotonic clock,
// and marking the provenance `.trusted` (on-device perception, never attacker-influenceable).
//
// Two invariants are enforced at this boundary:
//   • I6 (freeze, never snap): a `.frozen` (dropout) frame carries the HELD last-good point —
//     `PointerOutput.point` is already the held point, never (0,0) — and emits NO fresh referent
//     (n-best cleared): a stale frame must not assert a new target.
//   • I7 / N2 (one coordinate space): `PointerOutput.point` is ALREADY CG top-left, so it is
//     copied into `screenHit` UNCHANGED — the single cocoaToCG flip lives in Envelope and is not
//     re-applied here.

import Dispatch
import Foundation

struct PointingEventAdapter {
    // The one monotonic source, injected as a closure. We can't name `Envelope.MonotonicClock`
    // here — the module name is shadowed by Envelope's own `enum Envelope`, and the stdlib also
    // exposes a `MonotonicClock` — so the default replicates `MonotonicClock().now()` exactly
    // (`DispatchTime.now().uptimeNanoseconds`). Tests inject a deterministic `now`.
    private let now: () -> MonotonicInstant

    init(now: @escaping () -> MonotonicInstant = Self.monotonicNow) {
        self.now = now
    }

    /// The same instant `Envelope.MonotonicClock().now()` produces (one clock, INV-8).
    static func monotonicNow() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    /// Wrap a `PointerOutput` into a `PointingEvent`.
    ///
    /// - Parameters:
    ///   - output: the plugin's pointer output (CG top-left point + live/frozen + confidence).
    ///   - source: the modality provenance (`.hand_pose` or `.face_gaze`).
    ///   - hand: which hand produced it (default `.right`; two-handed is first-class downstream).
    ///   - nBestTargets: the ranked target cluster for a LIVE frame; ignored (cleared) when frozen.
    func event(
        from output: PointerOutput,
        source: EventSource,
        hand: PointingHand = .right,
        nBestTargets: [WindowOrRegionRef] = []
    ) -> PointingEvent {
        let isFrozen = output.state == .frozen
        // Held point copied straight through — already CG top-left (no re-flip, N2), never (0,0) (I6).
        let screenHit = PixelPoint(x: output.point.x, y: output.point.y)
        // A held frame asserts no fresh referent and carries no confidence (I6/I10 honesty).
        let targets = isFrozen ? [] : nBestTargets
        let confidence = isFrozen ? 0 : (output.confidence ?? 0)

        let header = EventHeader(
            source: source,
            tSrc: now(),
            conf: confidence,
            nBest: targets.count,
            taint: .trusted)

        return PointingEvent(
            header: header,
            ray: Self.nominalRay,
            screenHit: screenHit,
            nBestTargets: targets,
            hand: hand)
    }

    /// The 2D webcam path supplies a screen-plane hit, not a metric ray — `screenHit` is the
    /// meaningful payload. We carry a nominal forward ray so the `PointingEvent` shape is whole;
    /// downstream fusion keys on `screenHit`/`nBestTargets`, not this ray (ARCHITECTURE §5).
    private static let nominalRay = Ray3D(
        origin: Vector3(x: 0, y: 0, z: 0),
        direction: Vector3(x: 0, y: 0, z: -1))
}
