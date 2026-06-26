//
//  HeadPointerConfig.swift
//  DirectorSidecar
//
//  Folded in from src-tauri/sidecars/head-track/ConfigControl.swift (ADR 0005 step 5). The sidecar
//  received config + recenter over a stdin JSON line protocol (`{"kind":"config",…}` /
//  `{"kind":"recenter"}`) decoded by `parseControlCommand`. That seam is DELETED in-process: the host
//  now calls `HeadPointerService.applyConfig(_:)` / `.requestRecenter()` with this typed value
//  directly. Only the config value type survives the port. `Codable` so a later native settings store
//  (ADR 0005: Rust storage → Swift services) can decode the same `headPointer` shape verbatim.
//

import Foundation

enum MovementMode: String, Codable, Sendable {
    case edge
    case relative
}

struct HeadPointerConfig: Equatable, Sendable, Codable {
    var movementMode: MovementMode
    var speed: Double
    var distanceToEdge: Double

    // speed raised 5→8 for snappier out-of-the-box feel.
    // distanceToEdge stays 0.12 (raw head displacement before controlGain is applied).
    static let `default` = HeadPointerConfig(movementMode: .edge, speed: 8, distanceToEdge: 0.12)

    var sanitized: HeadPointerConfig {
        HeadPointerConfig(
            movementMode: movementMode,
            speed: HeadGeometry.clamp(speed, 1...30),
            distanceToEdge: HeadGeometry.clamp(distanceToEdge, 0.02...0.4)
        )
    }
}
