import { describe, expect, it } from "vitest";

import { safeParseCuaAgentAction } from "./cua-agent";

describe("CUA agent action contract", () => {
  it("accepts an element-index click — the AX-native primary action", () => {
    const result = safeParseCuaAgentAction({ kind: "click", elementIndex: 12 });
    expect(result.success).toBe(true);
  });

  it("accepts a window-local pixel click with an optional button (AX-blind fallback)", () => {
    expect(safeParseCuaAgentAction({ kind: "click_point", x: 42, y: 99.5 }).success).toBe(true);
    expect(
      safeParseCuaAgentAction({ kind: "click_point", x: 1, y: 2, button: "right" }).success,
    ).toBe(true);
  });

  it("accepts typing and value-setting against an element", () => {
    expect(
      safeParseCuaAgentAction({ kind: "type_text", elementIndex: 3, text: "hello" }).success,
    ).toBe(true);
    expect(safeParseCuaAgentAction({ kind: "set_value", elementIndex: 3, value: "" }).success).toBe(
      true,
    );
  });

  it("accepts a key press with optional modifiers and element focus", () => {
    expect(safeParseCuaAgentAction({ kind: "press_key", key: "return" }).success).toBe(true);
    expect(
      safeParseCuaAgentAction({
        kind: "press_key",
        key: "a",
        modifiers: ["cmd"],
        elementIndex: 5,
      }).success,
    ).toBe(true);
  });

  it("requires a hotkey chord of at least two keys", () => {
    expect(safeParseCuaAgentAction({ kind: "hotkey", keys: ["cmd", "c"] }).success).toBe(true);
    expect(safeParseCuaAgentAction({ kind: "hotkey", keys: ["cmd"] }).success).toBe(false);
  });

  it("accepts a directional scroll with optional granularity and amount", () => {
    expect(safeParseCuaAgentAction({ kind: "scroll", direction: "down" }).success).toBe(true);
    expect(
      safeParseCuaAgentAction({ kind: "scroll", direction: "up", by: "page", amount: 3 }).success,
    ).toBe(true);
    expect(safeParseCuaAgentAction({ kind: "scroll", direction: "sideways" }).success).toBe(false);
  });

  it("accepts a re-snapshot (look) and an app launch", () => {
    expect(safeParseCuaAgentAction({ kind: "snapshot" }).success).toBe(true);
    expect(safeParseCuaAgentAction({ kind: "launch_app", appName: "Cursor" }).success).toBe(true);
  });

  it("rejects an unknown action kind and a negative element index", () => {
    expect(safeParseCuaAgentAction({ kind: "teleport" }).success).toBe(false);
    expect(safeParseCuaAgentAction({ kind: "click", elementIndex: -1 }).success).toBe(false);
  });
});
