import type { CuaWindow } from "@handsoff/contracts";
import { describe, expect, it, vi } from "vitest";

import { resolveReferentTarget, resolveTargetFromReferent } from "./referent-target";

function win(over: Partial<CuaWindow>): CuaWindow {
  return {
    id: "w",
    title: "Untitled",
    app: "TextEdit",
    pid: 100,
    windowId: 1,
    availability: "available",
    accessStatus: "accessible",
    ...over,
  };
}

describe("resolveReferentTarget — referent → {pid, windowId}", () => {
  it("matches the window of the named app (case-insensitive)", () => {
    const windows = [win({ app: "Finder", pid: 7, windowId: 3 }), win({ app: "Safari" })];
    expect(resolveReferentTarget({ app: "finder" }, windows)).toEqual({ pid: 7, windowId: 3 });
  });

  it("prefers an app window whose title matches the referent title", () => {
    const windows = [
      win({ app: "Finder", title: "Downloads", pid: 7, windowId: 3 }),
      win({ app: "Finder", title: "Reports", pid: 7, windowId: 9 }),
    ];
    expect(resolveReferentTarget({ app: "Finder", title: "Reports" }, windows)).toEqual({
      pid: 7,
      windowId: 9,
    });
  });

  it("returns null when the named app has no usable window (never grounds elsewhere)", () => {
    const windows = [win({ app: "Safari", pid: 5, windowId: 2 })];
    expect(resolveReferentTarget({ app: "Finder" }, windows)).toBeNull();
  });

  it("falls back to the focused usable window when no app is named", () => {
    const windows = [
      win({ app: "Safari", pid: 5, windowId: 2, focused: false }),
      win({ app: "Notes", pid: 8, windowId: 4, focused: true }),
    ];
    expect(resolveReferentTarget(undefined, windows)).toEqual({ pid: 8, windowId: 4 });
  });

  it("falls back to the first usable window when nothing is focused", () => {
    const windows = [win({ app: "Notes", pid: 8, windowId: 4 })];
    expect(resolveReferentTarget({ app: "Current app" }, windows)).toEqual({ pid: 8, windowId: 4 });
  });

  it("skips unusable windows (unavailable, inaccessible, or the cua driver itself)", () => {
    const windows = [
      win({ app: "CUA Driver", pid: 1, windowId: 1 }),
      win({ app: "Finder", availability: "closed", pid: 2, windowId: 2 }),
      win({ app: "Finder", accessStatus: "restricted", pid: 3, windowId: 3 }),
      win({ app: "Finder", pid: 4, windowId: 4 }),
    ];
    expect(resolveReferentTarget({ app: "Finder" }, windows)).toEqual({ pid: 4, windowId: 4 });
  });

  it("returns null when the chosen window lacks a pid or window id", () => {
    const windows = [win({ app: "Finder", pid: undefined, windowId: 3 })];
    expect(resolveReferentTarget({ app: "Finder" }, windows)).toBeNull();
  });
});

describe("resolveTargetFromReferent — lists windows then resolves", () => {
  it("invokes cua_list_windows and resolves the target", async () => {
    const windows = [win({ app: "Finder", pid: 7, windowId: 3 })];
    const invoke = vi.fn().mockResolvedValue(windows);
    const target = await resolveTargetFromReferent(invoke, { app: "Finder" });
    expect(invoke).toHaveBeenCalledWith("cua_list_windows");
    expect(target).toEqual({ pid: 7, windowId: 3 });
  });

  it("returns null when the driver call fails rather than throwing", async () => {
    const invoke = vi.fn().mockRejectedValue(new Error("driver offline"));
    expect(await resolveTargetFromReferent(invoke, { app: "Finder" })).toBeNull();
  });
});
