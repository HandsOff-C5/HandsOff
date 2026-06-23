import { describe, expect, it } from "vitest";

import { Surface, SurfaceBounds } from "./surface";

const bounds = { x: 0, y: 0, w: 1920, h: 1080 };
const surface = { id: "win-1", bounds, displayId: "display-0", title: "Editor" };

describe("surface contract (provisional — pending Naama sign-off)", () => {
  it("Surface validates a well-formed surface and exposes its bounds", () => {
    expect(Surface.parse(surface).id).toBe("win-1");
    expect(Surface.parse(surface).bounds.w).toBe(1920);
  });

  it("Surface allows an absent title (optional)", () => {
    const untitled = { id: "win-1", bounds, displayId: "display-0" };
    expect(Surface.parse(untitled).title).toBeUndefined();
  });

  it("SurfaceBounds rejects non-positive width or height", () => {
    expect(() => SurfaceBounds.parse({ x: 0, y: 0, w: 0, h: 1080 })).toThrow();
    expect(() => SurfaceBounds.parse({ x: 0, y: 0, w: 1920, h: -1 })).toThrow();
  });

  it("SurfaceBounds allows negative origin (secondary monitor offset in global px space)", () => {
    expect(SurfaceBounds.parse({ x: -1920, y: 0, w: 1920, h: 1080 }).x).toBe(-1920);
  });

  it("Surface requires a displayId so candidates resolve to a physical display", () => {
    const noDisplay = { id: "win-1", bounds, title: "Editor" };
    expect(() => Surface.parse(noDisplay)).toThrow();
  });
});
