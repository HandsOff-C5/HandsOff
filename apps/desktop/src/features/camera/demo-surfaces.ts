import type { Surface, SurfaceSnapshot } from "@handsoff/contracts";

// DEMO STAND-IN for the live surfaces the desktop host will provide (area:desktop —
// Naama; the provisional Surface contract still needs her sign-off). Two halves of a
// 1080p screen so pointing left/right resolves to a distinct target until real
// app/window surfaces are wired in.
export const DEMO_SCREEN_BOUNDS = { x: 0, y: 0, w: 1920, h: 1080 };

export const demoSurfaces: Surface[] = [
  {
    id: "left-window",
    bounds: { x: 0, y: 0, w: 960, h: 1080 },
    displayId: "display-0",
    title: "Left",
  },
  {
    id: "right-window",
    bounds: { x: 960, y: 0, w: 960, h: 1080 },
    displayId: "display-0",
    title: "Right",
  },
];

// Bridge a demo pointing target (Surface geometry) into the audit/intent
// SurfaceSnapshot the fusion engine consumes (#35). Until the desktop host
// supplies real app/window snapshots, a demo target is synthesized as an
// available, accessible "Demo" surface so "point + speak" resolves end-to-end.
export function demoSurfaceSnapshot(targetId: string): SurfaceSnapshot {
  const surface = demoSurfaces.find((s) => s.id === targetId);
  return {
    id: targetId,
    title: surface?.title ?? targetId,
    app: "Demo",
    availability: "available",
    accessStatus: "accessible",
  };
}
