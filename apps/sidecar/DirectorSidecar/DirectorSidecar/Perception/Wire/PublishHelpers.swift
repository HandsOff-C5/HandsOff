// PublishHelpers — the small publish-side enums + clock that the ported PerceptionPublisher uses.
//
// In HO-rebuild these lived in `HandsOffLab/Contracts/Pointer+Publish.swift` and
// `Gaze+Contracts.swift`. DirectorSidecar already owns the wire `Pointer` / `CursorPositionPayload`
// / `GazeFocus` / `GazeRegion` types (String-typed `kind`/`state`/`sizeClass`), so we only need
// these typed helpers to build them and a single epoch-ms stamp. All `internal`.

import Foundation

/// The two pointer kinds the bridge distinguishes. Maps to `Pointer.kind` (a String on the wire).
enum PointerKind: String, Sendable { case user, agent }

/// Pointer motion state. Maps to `Pointer.state` (a String on the wire).
enum PointerState: String, Sendable { case idle, moving, locked, poof }

/// Advisory gaze region size class. Maps to `GazeFocus.sizeClass` (a String? on the wire).
enum GazeSizeClass: String, Sendable { case element, block, region }

/// Epoch-millisecond stamps for the high-rate bridge topics (cursorPosition / gazeFocus).
enum WireClock {
    /// Milliseconds since the Unix epoch.
    static func epochMillis(_ date: Date = Date()) -> Double {
        date.timeIntervalSince1970 * 1000
    }
}
