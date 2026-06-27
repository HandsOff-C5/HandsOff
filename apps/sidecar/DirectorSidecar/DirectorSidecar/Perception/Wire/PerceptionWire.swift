// PerceptionWire — the trimmed event/header/clock vocabulary the ported perception layer needs.
//
// This is a focused port of the HO-rebuild `Envelope` module value types that the perception
// fan-out (PerceptionBus → PointingEventAdapter → PointingEventRing) depends on. Per the migration
// plan we DO NOT import the whole Envelope module; we adapt only the needed shapes into the
// DirectorSidecar app target. Two renames vs the source avoid collisions in this target:
//   • `Hand` → `PointingHand`  (DirectorSidecar already has `Contracts.Hand`, the 21-landmark hand)
//   • `WindowRef` → `PerceptionWindowRef`  (Carbon/HIToolbox leaks an opaque `WindowRef` via AppKit)
// All types are `internal` (single-module app target).

import Dispatch
import Foundation

// MARK: - One monotonic clock

/// A timestamp taken from the one monotonic clock, in nanoseconds.
struct MonotonicInstant: Comparable, Equatable, Codable, Sendable {
    let nanoseconds: UInt64
    init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
    static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

/// The single monotonic clock source. Successive reads are non-decreasing.
struct MonotonicClock: Sendable {
    init() {}
    func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}

// MARK: - Shared header

/// The provenance source of a perception event. HandsOff emits the face-gaze and hand-pose
/// modalities; the rest are carried for shape-parity with the source contract.
enum EventSource: String, Codable, CaseIterable, Sendable {
    case iphone_depth
    case webcam_2d
    case voice
    case screen_ax
    case vision_ocr
    case face_gaze
    case hand_pose
}

/// Provenance taint: trusted vs attacker-influenceable. On-device perception is `.trusted`.
enum Taint: String, Codable, CaseIterable, Sendable {
    case trusted
    case attacker_influenceable
}

/// The common header every perception event carries.
struct EventHeader: Codable, Equatable, Sendable {
    var source: EventSource
    var tSrc: MonotonicInstant
    var conf: Double
    var nBest: Int
    var taint: Taint

    enum CodingKeys: String, CodingKey {
        case source
        case tSrc = "t_src"
        case conf
        case nBest = "n_best"
        case taint
    }

    init(source: EventSource, tSrc: MonotonicInstant, conf: Double, nBest: Int, taint: Taint) {
        self.source = source
        self.tSrc = tSrc
        self.conf = conf
        self.nBest = nBest
        self.taint = taint
    }
}

// MARK: - Shared references

/// A 3D vector (ray origin / direction).
struct Vector3: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
    init(x: Double, y: Double, z: Double) {
        self.x = x; self.y = y; self.z = z
    }
}

/// A pointing ray. `origin` is observed only on the depth path; the 2D webcam path supplies
/// direction with an inferred origin.
struct Ray3D: Codable, Equatable, Sendable {
    var origin: Vector3
    var direction: Vector3
    init(origin: Vector3, direction: Vector3) {
        self.origin = origin
        self.direction = direction
    }
}

/// A ranked target candidate: a window or screen region with its own confidence. The pointing
/// n-best is a target cluster, NOT a pixel cursor.
struct WindowOrRegionRef: Codable, Equatable, Sendable {
    var id: String
    var conf: Double
    init(id: String, conf: Double) {
        self.id = id
        self.conf = conf
    }
}

/// A window in the AX snapshot: bundle id, title, CG-global frame, display id.
/// (Renamed from the source `WindowRef` to avoid the Carbon/HIToolbox `WindowRef` collision.)
struct PerceptionWindowRef: Codable, Equatable, Sendable {
    var appBundleId: String
    var title: String
    var frame: CGGlobalRect
    var display: Int
    init(appBundleId: String, title: String, frame: CGGlobalRect, display: Int) {
        self.appBundleId = appBundleId
        self.title = title
        self.frame = frame
        self.display = display
    }
}

/// A display: id and its CG-global bounds.
struct DisplayRef: Codable, Equatable, Sendable {
    var id: Int
    var bounds: CGGlobalRect
    init(id: Int, bounds: CGGlobalRect) {
        self.id = id
        self.bounds = bounds
    }
}

/// The currently focused field: role, current value, editability.
struct FieldRef: Codable, Equatable, Sendable {
    var role: String
    var value: String
    var editable: Bool
    init(role: String, value: String, editable: Bool) {
        self.role = role
        self.value = value
        self.editable = editable
    }
}

/// Handedness — two-handed is first-class. (Renamed from the source `Hand`.)
enum PointingHand: String, Codable, Sendable {
    case left
    case right
}

// MARK: - Events

/// A pointing event: the common header plus the modality-specific pointing payload.
struct PointingEvent: Codable, Equatable, Sendable {
    var header: EventHeader
    var ray: Ray3D
    /// ray→screen-plane hit; absent if no plane hit.
    var screenHit: PixelPoint?
    /// Ranked target cluster (NOT a pixel cursor).
    var nBestTargets: [WindowOrRegionRef]
    var hand: PointingHand

    enum CodingKeys: String, CodingKey {
        case header, ray
        case screenHit = "screen_hit"
        case nBestTargets = "n_best"
        case hand
    }

    init(
        header: EventHeader,
        ray: Ray3D,
        screenHit: PixelPoint?,
        nBestTargets: [WindowOrRegionRef],
        hand: PointingHand
    ) {
        self.header = header
        self.ray = ray
        self.screenHit = screenHit
        self.nBestTargets = nBestTargets
        self.hand = hand
    }
}

/// A screen event (AX snapshot) — the candidate window set NBestCluster ranks against.
struct ScreenEvent: Codable, Equatable, Sendable {
    var header: EventHeader
    var windows: [PerceptionWindowRef]
    var displays: [DisplayRef]
    var focusedField: FieldRef?

    enum CodingKeys: String, CodingKey {
        case header, windows, displays
        case focusedField = "focused_field"
    }

    init(
        header: EventHeader,
        windows: [PerceptionWindowRef],
        displays: [DisplayRef],
        focusedField: FieldRef?
    ) {
        self.header = header
        self.windows = windows
        self.displays = displays
        self.focusedField = focusedField
    }
}
