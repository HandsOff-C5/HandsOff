import { describe, expect, it } from "vitest";

import { COMPUTER_ACTION_KINDS, safeParseComputerAction } from "./computer-use";

describe("computer-use action schema", () => {
  it("parses a bare screenshot action", () => {
    const result = safeParseComputerAction({ action: "screenshot" });
    expect(result.success).toBe(true);
    if (result.success) expect(result.data.action).toBe("screenshot");
  });

  it("parses a left_click with an integer coordinate tuple", () => {
    const result = safeParseComputerAction({ action: "left_click", coordinate: [500, 300] });
    expect(result.success).toBe(true);
    if (result.success && result.data.action === "left_click") {
      expect(result.data.coordinate).toEqual([500, 300]);
    }
  });

  it("accepts a modifier key on a click via the `text` field", () => {
    const result = safeParseComputerAction({
      action: "left_click",
      coordinate: [10, 20],
      text: "shift",
    });
    expect(result.success).toBe(true);
  });

  it("rejects a click whose coordinate is not a two-number tuple", () => {
    expect(safeParseComputerAction({ action: "left_click", coordinate: [500] }).success).toBe(
      false,
    );
    expect(safeParseComputerAction({ action: "left_click", coordinate: [1, 2, 3] }).success).toBe(
      false,
    );
    expect(safeParseComputerAction({ action: "left_click" }).success).toBe(false);
  });

  it("parses a type action and rejects one missing text", () => {
    expect(safeParseComputerAction({ action: "type", text: "Hello, world!" }).success).toBe(true);
    expect(safeParseComputerAction({ action: "type" }).success).toBe(false);
  });

  it("parses a key combination", () => {
    expect(safeParseComputerAction({ action: "key", text: "ctrl+s" }).success).toBe(true);
  });

  it("parses a scroll with direction + amount and rejects a bad direction", () => {
    expect(
      safeParseComputerAction({
        action: "scroll",
        coordinate: [500, 400],
        scroll_direction: "down",
        scroll_amount: 3,
      }).success,
    ).toBe(true);
    expect(
      safeParseComputerAction({
        action: "scroll",
        coordinate: [500, 400],
        scroll_direction: "diagonal",
        scroll_amount: 3,
      }).success,
    ).toBe(false);
  });

  it("parses a left_click_drag with start + end coordinates", () => {
    const result = safeParseComputerAction({
      action: "left_click_drag",
      start_coordinate: [10, 10],
      coordinate: [200, 200],
    });
    expect(result.success).toBe(true);
  });

  it("parses a hold_key and a wait with a duration", () => {
    expect(
      safeParseComputerAction({ action: "hold_key", text: "shift", duration: 2 }).success,
    ).toBe(true);
    expect(safeParseComputerAction({ action: "wait", duration: 1 }).success).toBe(true);
  });

  it("parses a zoom with a four-number region and rejects a three-number region", () => {
    expect(safeParseComputerAction({ action: "zoom", region: [100, 200, 400, 350] }).success).toBe(
      true,
    );
    expect(safeParseComputerAction({ action: "zoom", region: [100, 200, 400] }).success).toBe(
      false,
    );
  });

  it("rejects an unknown action verb", () => {
    expect(safeParseComputerAction({ action: "teleport", coordinate: [1, 2] }).success).toBe(false);
  });

  it("enumerates every supported action kind", () => {
    // Guards the union against silent drift — the Rust loop and the approval UI
    // both rely on this being the complete computer_20251124 action set.
    expect([...COMPUTER_ACTION_KINDS].sort()).toEqual(
      [
        "screenshot",
        "left_click",
        "right_click",
        "middle_click",
        "double_click",
        "triple_click",
        "mouse_move",
        "left_click_drag",
        "left_mouse_down",
        "left_mouse_up",
        "scroll",
        "type",
        "key",
        "hold_key",
        "wait",
        "cursor_position",
        "zoom",
      ].sort(),
    );
  });
});
