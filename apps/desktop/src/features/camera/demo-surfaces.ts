import type { Surface } from "@handsoff/contracts";

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
