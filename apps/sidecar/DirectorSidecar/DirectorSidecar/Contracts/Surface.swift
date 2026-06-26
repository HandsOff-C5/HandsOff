//
//  Surface.swift
//  DirectorSidecar
//
//  Port of @handsoff/contracts surface.ts `surfaceSnapshotSchema` — the point-in-time
//  desktop surface (app/window) a referent resolved to. The audit trail stores it *as it
//  was at selection time*, so a replay shows the surface the user actually pointed at.
//
//  Distinct from the lite top-level `SurfaceSnapshot` (Bridge/LoopTypes.swift): there the
//  availability/accessStatus are loosely-typed `String?` for forgiving HUD decode; here they
//  are the strict TS enums so a contract drift fails the decode.
//

import Foundation

extension Contracts {
    /// Whether the surface was on screen and actionable when the snapshot was taken.
    enum SurfaceAvailability: String, Codable, Sendable, CaseIterable {
        case available
        case minimized
        case closed
        case unknown
    }

    /// Whether the OS accessibility (AX) layer could read/drive the surface.
    /// `restricted` == AX access denied or unavailable for that surface.
    enum SurfaceAccessStatus: String, Codable, Sendable, CaseIterable {
        case accessible
        case restricted
        case unknown
    }

    /// `surfaceSnapshotSchema`. `pid`/`windowId` are each optionally present (macOS may
    /// not expose either). `title` may be empty (`z.string()`), `app`/`id` are non-empty
    /// TS-side — not re-validated here; the boundary parse already happened upstream.
    struct SurfaceSnapshot: Codable, Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let app: String
        let pid: Int?
        let windowId: Int?
        let availability: SurfaceAvailability
        let accessStatus: SurfaceAccessStatus
    }
}
