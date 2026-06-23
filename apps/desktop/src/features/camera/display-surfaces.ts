import type { Surface, SurfaceSnapshot } from "@handsoff/contracts";
import type { Display } from "@handsoff/gesture";

import type { DisplayInfo } from "./useGestureOverlay";

// Maps the live CoreGraphics display layout into the pointing pipeline's own coordinate
// space. Until area:desktop supplies real app/window surfaces, each MONITOR is itself the
// pointable surface: a calibrated point resolves to the display it lands on, so "point +
// speak" still resolves end-to-end and there are no fake demo windows. Coordinate spaces are
// shared verbatim — both SurfaceBounds and the calibration output already live in the global
// virtual-desktop px space the sidecar reports.

// The gesture lane's arbitration `Display` (global-px bounds, keyed by a stable id).
export const toArbitrationDisplay = (info: DisplayInfo): Display => ({
  id: info.id,
  bounds: { x: info.x, y: info.y, w: info.width, h: info.height },
});

export const toArbitrationDisplays = (infos: DisplayInfo[]): Display[] =>
  infos.map(toArbitrationDisplay);

// Each display as one pointable Surface so `toCandidate` has something to hit-test while real
// app/window surfaces are still upstream (area:desktop).
export const toDisplaySurfaces = (infos: DisplayInfo[]): Surface[] =>
  infos.map((info) => ({
    id: info.id,
    displayId: info.id,
    bounds: { x: info.x, y: info.y, w: info.width, h: info.height },
    title: `Display ${info.id}`,
  }));

// A best-effort audit snapshot for the display a referent resolved to — the metadata the
// intent engine needs while the live app/window snapshot is still a desktop-host concern.
export const displaySurfaceSnapshot = (
  displayId: string,
  infos: DisplayInfo[],
): SurfaceSnapshot => {
  const info = infos.find((d) => d.id === displayId);
  return {
    id: displayId,
    title: info ? `Display ${info.id}` : displayId,
    app: "Display",
    availability: "available",
    accessStatus: "accessible",
  };
};
