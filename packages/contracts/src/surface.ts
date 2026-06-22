import { z } from "zod";

// A point-in-time snapshot of the desktop surface (app/window) a referent
// resolved to, normalized to the fields epic #6 defines: title, app, pid/window
// id, availability, and access status. The audit trail stores the snapshot *as
// it was at selection time*, so a replay shows the surface the user actually
// pointed at even if the live window later moved, closed, or changed title.
//
// Scope: metadata and references only — binary screenshot retention is a
// separate concern (#23 scope boundary).

// Whether the surface was on screen and actionable when the snapshot was taken.
export const SURFACE_AVAILABILITIES = ["available", "minimized", "closed", "unknown"] as const;

export const surfaceAvailabilitySchema = z.enum(SURFACE_AVAILABILITIES);
export type SurfaceAvailability = z.infer<typeof surfaceAvailabilitySchema>;

// Whether the OS accessibility (AX) layer could read/drive the surface — the
// product prioritizes AX-rich targets (AD3). `restricted` means AX access was
// denied or unavailable for that surface.
export const SURFACE_ACCESS_STATUSES = ["accessible", "restricted", "unknown"] as const;

export const surfaceAccessStatusSchema = z.enum(SURFACE_ACCESS_STATUSES);
export type SurfaceAccessStatus = z.infer<typeof surfaceAccessStatusSchema>;

export const surfaceSnapshotSchema = z.object({
  id: z.string().min(1),
  title: z.string(),
  app: z.string().min(1),
  // macOS identifies a window by pid + window id; either may be unavailable.
  pid: z.number().int().nonnegative().optional(),
  windowId: z.number().int().nonnegative().optional(),
  availability: surfaceAvailabilitySchema,
  accessStatus: surfaceAccessStatusSchema,
});
export type SurfaceSnapshot = z.infer<typeof surfaceSnapshotSchema>;

// ---------------------------------------------------------------------------
// PROVISIONAL surface geometry for the pointing pipeline (#26 calibration →
// candidate). A `Surface` here is one pointable target (a display or window)
// with screen bounds — distinct from the audit `surfaceSnapshotSchema` above.
// Produced by the desktop host (area:desktop); defined here so #26 calibration
// is not blocked on it. Shape + coordinate space are PROVISIONAL (Naama sign-off).
//
// COORDINATE SPACE — global multi-monitor virtual-desktop pixels.
//   Both `bounds` and the `screenXY` produced by calibration (`applyTransform`) live
//   in the SAME space: origin at the top-left of the primary display, x grows right,
//   y grows down; secondary displays sit at their OS-reported offset (which may be
//   negative — a monitor to the left of primary has x < 0). This mirrors the OS
//   virtual-screen geometry (Tauri monitor `position`/`size`). Hit-testing
//   `toCandidate(screenXY, surfaces)` is only meaningful while both share this space.
export const SurfaceBounds = z.object({
  x: z.number(),
  y: z.number(),
  w: z.number().positive(),
  h: z.number().positive(),
});
export type SurfaceBounds = z.infer<typeof SurfaceBounds>;

export const Surface = z.object({
  id: z.string(),
  bounds: SurfaceBounds,
  displayId: z.string(),
  title: z.string().optional(),
});
export type Surface = z.infer<typeof Surface>;
