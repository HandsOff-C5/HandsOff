import type { ActionStep } from "@handsoff/contracts";
import { fakeActionTarget } from "@handsoff/testkit";
import { describe, expect, it } from "vitest";

import { translateStep } from "./translate-plan";

describe("translateStep", () => {
  it("translates the typed 6-kind steps to driver action requests", () => {
    const target = fakeActionTarget();
    expect(translateStep({ id: "1", kind: "click_element", label: "Click", target })).toEqual({
      kind: "click",
      target,
    });
    expect(
      translateStep({ id: "2", kind: "type_text", label: "Type", target, text: "hi" }),
    ).toEqual({ kind: "type_text", target, text: "hi" });
    expect(
      translateStep({ id: "3", kind: "launch_app", label: "Open", appName: "Notes" }),
    ).toMatchObject({ kind: "launch_app", appName: "Notes" });
  });

  it("throws on a generic tool_call step — the loop dispatches it via driver.call, not here (U3b)", () => {
    const step: ActionStep = {
      id: "1",
      kind: "tool_call",
      label: "Scroll down",
      tool: "scroll",
      args: { pid: 42, direction: "down" },
    };
    expect(() => translateStep(step)).toThrow(/cannot translate a generic tool_call step: scroll/);
  });
});
