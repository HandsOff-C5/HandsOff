//
//  SurfaceGeometry.swift
//  DirectorSidecar
//
//  Port of the @handsoff/contracts surface.ts PROVISIONAL pointing geometry — `SurfaceBounds`
//  and `Surface`: one pointable target (display or window) with screen bounds. DISTINCT from
//  the audit `SurfaceSnapshot` (Surface.swift): that is the point-in-time selection record;
//  this is live hit-test geometry for the calibration → candidate pipeline (#26).
//
//  COORDINATE SPACE — global multi-monitor virtual-desktop pixels (the same space the
//  calibration output `applyTransform` lives in): origin at the top-left of the primary
//  display, x grows right, y grows down; secondary displays sit at their OS-reported offset
//  (which may be NEGATIVE — a monitor left of primary has x < 0). `toCandidate` hit-testing
//  is only meaningful while both the point and these bounds share this space.
//

import Foundation

extension Contracts {
    /// Screen bounds in global virtual-desktop px. `w`/`h` are positive TS-side (not
    /// re-validated here; the boundary parse already happened upstream).
    struct SurfaceBounds: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }

    /// One pointable target — a display or window — with screen bounds. `title` optional.
    struct Surface: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let bounds: SurfaceBounds
        let displayId: String
        let title: String?

        init(id: String, bounds: SurfaceBounds, displayId: String, title: String? = nil) {
            self.id = id
            self.bounds = bounds
            self.displayId = displayId
            self.title = title
        }
    }
}
