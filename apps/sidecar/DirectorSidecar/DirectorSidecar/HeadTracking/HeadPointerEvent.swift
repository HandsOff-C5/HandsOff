//
//  HeadPointerEvent.swift
//  DirectorSidecar
//
//  Replaces src-tauri/sidecars/head-track/WireEvents.swift (ADR 0005 step 5). The sidecar serialized
//  start/stop/point/error as newline-delimited JSON on stdout, which Rust (head_track.rs) parsed and
//  re-emitted as the `stt://head` Tauri event. In-process that whole wire is DELETED: the service
//  publishes these typed values over an `AsyncStream<HeadPointerEvent>` (PORTING.md: Tauri events →
//  AsyncStream). A later consumer maps `.point` straight onto the bridge `cursorPosition` topic.
//
//  Type edge cases preserved from the wire:
//   - `confidence` is clamped to 0…1 at construction (the wire clamped at encode time).
//   - `yaw` / `pitch` stay `Double?` (the wire emitted JSON `null`); no sentinel substitution.
//   - the point's x/y are in CoreGraphics global top-left contract space (already flipped via
//     HeadGeometry.appKitToGlobalTopLeft), NOT the AppKit space the overlay panel uses.
//   - `ts` is epoch milliseconds (Int64), matching the wire `ts`.
//

import Foundation

struct HeadPoint: Equatable, Sendable {
    let x: Double
    let y: Double
    let yaw: Double?
    let pitch: Double?
    let confidence: Double
    let ts: Int64

    init(x: Double, y: Double, yaw: Double?, pitch: Double?, confidence: Double, ts: Int64) {
        self.x = x
        self.y = y
        self.yaw = yaw
        self.pitch = pitch
        self.confidence = HeadGeometry.clamp(confidence, 0...1)
        self.ts = ts
    }
}

enum HeadPointerEvent: Equatable, Sendable {
    case started(ts: Int64)
    case point(HeadPoint)
    case stopped(ts: Int64)
    case error(message: String, ts: Int64)

    /// Epoch milliseconds — the same clock the sidecar's `epochMillis()` used for wire `ts`.
    static func epochMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
