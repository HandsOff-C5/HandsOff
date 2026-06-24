import { describe, expect, it } from "vitest";

import { describeCuaFailure } from "./failure";

describe("CUA failure recovery copy", () => {
  it("maps permission failures to user-readable recovery steps", () => {
    expect(
      describeCuaFailure({ status: "blocked", reason: "Accessibility permission denied" }),
    ).toEqual({
      kind: "permission",
      message: "HandsOff needs Accessibility permission before it can control the selected app.",
      nextStep: "Enable Accessibility for HandsOff, then re-check readiness and retry.",
    });

    expect(
      describeCuaFailure({ status: "failed", error: "Screen Recording permission denied" }),
    ).toEqual({
      kind: "permission",
      message: "HandsOff needs Screen Recording permission before it can inspect the target.",
      nextStep: "Enable Screen Recording for HandsOff, then retry.",
    });
  });

  it("maps unavailable, minimized, off-Space, and canvas-heavy failures", () => {
    for (const reason of [
      "Target window is unavailable",
      "CUA window disappeared before state capture",
      "Target appears minimized or off-Space",
    ]) {
      expect(describeCuaFailure({ status: "blocked", reason })).toEqual({
        kind: "target_unavailable",
        message: "The selected window is not reachable right now.",
        nextStep: "Bring it back on screen or switch to its Space, then point and speak again.",
      });
    }

    expect(
      describeCuaFailure({ status: "failed", error: "canvas exposes no accessible element" }),
    ).toEqual({
      kind: "canvas_limited",
      message: "The selected area does not expose accessible controls.",
      nextStep: "Use a visible native control, describe the target more clearly, or retry.",
    });
  });
});
