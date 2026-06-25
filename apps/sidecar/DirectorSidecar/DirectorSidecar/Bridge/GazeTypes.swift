//
//  GazeTypes.swift
//  DirectorSidecar
//
//  G7 wire type for the NEW `gazeFocus` region topic (director-bridge-contract.md §4.1.2) — the
//  predicted-referent REGION the eye-gaze brackets morph to. Distinct from `cursorPosition` (a
//  point): the brackets need a rect, which a point cannot carry. Co-owned engine publisher (Hirom's
//  multi-input CV); DEV-mocked until it lands. Virtual-desktop px, top-left origin, y-down.
//

import Foundation

/// The predicted referent rectangle (virtual-desktop px, top-left, y-down).
struct GazeRegion: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

/// `gazeFocus` payload — `{ bounds, confidence, sizeClass?, ts }`.
struct GazeFocus: Codable, Sendable, Equatable {
    let bounds: GazeRegion
    let confidence: Double          // 0…1; below threshold → dim + hold last good
    let sizeClass: String?          // "element" | "block" | "region" — advisory
    let ts: Double                  // epoch ms; drop frames older than the last applied ts
}
