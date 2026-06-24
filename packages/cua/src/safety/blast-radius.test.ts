import { describe, expect, it } from "vitest";

import type { CuaAgentAction } from "@handsoff/contracts";

import { classifyCuaAgentAction } from "./blast-radius";

describe("blast-radius classifier for CUA agent actions", () => {
  it("treats a snapshot (look) as read_only", () => {
    expect(classifyCuaAgentAction({ kind: "snapshot" })).toBe("read_only");
  });

  it("treats scrolling as reversible (changes the view, not state)", () => {
    expect(classifyCuaAgentAction({ kind: "scroll", direction: "down" })).toBe("reversible");
  });

  it("treats clicks, typing, keys, and launches as mutating (cannot be assumed reversible)", () => {
    const mutating: CuaAgentAction[] = [
      { kind: "click", elementIndex: 1 },
      { kind: "click_point", x: 1, y: 2 },
      { kind: "type_text", elementIndex: 1, text: "rm -rf" },
      { kind: "set_value", elementIndex: 1, value: "x" },
      { kind: "press_key", key: "return" },
      { kind: "hotkey", keys: ["cmd", "s"] },
      { kind: "launch_app", appName: "Cursor" },
    ];
    for (const action of mutating) {
      expect(classifyCuaAgentAction(action)).toBe("mutating");
    }
  });
});
