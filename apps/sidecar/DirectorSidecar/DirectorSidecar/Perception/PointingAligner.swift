// PointingAligner — the live consumer of the bus's 300ms fusion ring (the "S4 Aligner").
//
// The concurrent PerceptionBus rings one `PointingEvent` per plugin per frame, each carrying the
// NBestCluster cluster for that modality's screen hit. This aligner is the read seam over that ring:
// it FUSES the most-recent event from each modality inside the fusion window into ONE ranked target
// cluster, so a consumer (the intent intake) sees a single "what is the user pointing/looking at"
// answer rather than two competing per-modality lists.
//
// Fusion (deterministic — INV-14): take the latest event PER SOURCE within the window (a newer frame
// supersedes an older one from the same modality), weight each candidate's confidence by its source
// (the HAND ray is more precise than the head gaze, so it leads), accumulate per target id, then rank
// confidence↓, id↑. A frozen frame carries no cluster (the adapter cleared it, I6), so it never
// asserts a target. Pure given an injected clock — headless-testable.

import Foundation

final class PointingAligner {

    /// Per-modality trust weight applied to each candidate's confidence before accumulation. The
    /// hand ray is the precise cursor; the face gaze is the coarser region (mirrors the intake's
    /// gesture-0.9 / head-0.6 weighting).
    static func defaultWeight(for source: EventSource) -> Double {
        switch source {
        case .hand_pose: return 1.0
        case .face_gaze: return 0.6
        default: return 0.5
        }
    }

    /// The fused pointing answer over one window of the ring.
    struct Fused: Equatable {
        /// The merged ranked target cluster (confidence↓, id↑).
        let targets: [WindowOrRegionRef]
        /// The modalities that contributed (latest-per-source), newest first.
        let sources: [EventSource]
    }

    private let ring: PointingEventRing
    private let now: () -> MonotonicInstant
    private let weight: (EventSource) -> Double

    init(
        ring: PointingEventRing,
        now: @escaping () -> MonotonicInstant = PointingEventAdapter.monotonicNow,
        weight: @escaping (EventSource) -> Double = PointingAligner.defaultWeight
    ) {
        self.ring = ring
        self.now = now
        self.weight = weight
    }

    /// Fuse the ring contents within `window` ms (default: the ring's own fusion window) into one
    /// ranked cluster. Returns `nil` when no event with any target is in the window.
    func fuse(window: Double? = nil) -> Fused? {
        let events = ring.within(window: window, now: now())
        guard !events.isEmpty else { return nil }

        // Latest event per source — a newer frame from the same modality supersedes the older one.
        var latestBySource: [EventSource: PointingEvent] = [:]
        for event in events {
            let src = event.header.source
            if let existing = latestBySource[src], existing.header.tSrc >= event.header.tSrc { continue }
            latestBySource[src] = event
        }

        // Accumulate weighted confidence per target id across the contributing modalities.
        var weighted: [String: Double] = [:]
        for (src, event) in latestBySource {
            let w = weight(src)
            for target in event.nBestTargets {
                weighted[target.id, default: 0] += target.conf * w
            }
        }
        guard !weighted.isEmpty else { return nil }

        let targets = weighted
            .map { WindowOrRegionRef(id: $0.key, conf: $0.value) }
            .sorted { lhs, rhs in
                if lhs.conf != rhs.conf { return lhs.conf > rhs.conf }
                return lhs.id < rhs.id
            }
        // Sources newest-first, for observability.
        let sources = latestBySource
            .sorted { $0.value.header.tSrc > $1.value.header.tSrc }
            .map(\.key)
        return Fused(targets: targets, sources: sources)
    }

    /// The single best fused target in the window, or `nil` if the user is pointing at nothing.
    func top(window: Double? = nil) -> WindowOrRegionRef? {
        fuse(window: window)?.targets.first
    }
}
