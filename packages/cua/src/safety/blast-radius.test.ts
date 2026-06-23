import { describe, expect, it } from "vitest";

import type { ComputerAction } from "@handsoff/contracts";

import { classifyComputerAction } from "./blast-radius";

describe("blast-radius classifier for computer-use actions", () => {
  it("treats observe-only actions as read_only", () => {
    const readOnly: ComputerAction[] = [
      { action: "screenshot" },
      { action: "cursor_position" },
      { action: "mouse_move", coordinate: [1, 2] },
      { action: "zoom", region: [0, 0, 10, 10] },
      { action: "wait", duration: 1 },
    ];
    for (const action of readOnly) {
      expect(classifyComputerAction(action)).toBe("read_only");
    }
  });

  it("treats scrolling as reversible (changes the view, not state)", () => {
    expect(
      classifyComputerAction({
        action: "scroll",
        coordinate: [1, 2],
        scroll_direction: "down",
        scroll_amount: 3,
      }),
    ).toBe("reversible");
  });

  it("treats clicks, typing, and key presses as mutating (cannot be assumed reversible)", () => {
    const mutating: ComputerAction[] = [
      { action: "left_click", coordinate: [1, 2] },
      { action: "right_click", coordinate: [1, 2] },
      { action: "middle_click", coordinate: [1, 2] },
      { action: "double_click", coordinate: [1, 2] },
      { action: "triple_click", coordinate: [1, 2] },
      { action: "left_click_drag", start_coordinate: [1, 2], coordinate: [3, 4] },
      { action: "left_mouse_down", coordinate: [1, 2] },
      { action: "left_mouse_up", coordinate: [1, 2] },
      { action: "type", text: "rm -rf" },
      { action: "key", text: "ctrl+s" },
      { action: "hold_key", text: "shift", duration: 1 },
    ];
    for (const action of mutating) {
      expect(classifyComputerAction(action)).toBe("mutating");
    }
  });
});
