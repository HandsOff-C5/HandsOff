import { describe, expect, it } from "vitest";

import { riskForToolCall, riskForToolName, effectiveToolCallRisk } from "./tool-risk";
import type { DriverTool } from "./tool-risk";

// The implementation lives in @handsoff/contracts; intent re-exports it (boundary
// rule — actions cannot import intent). These tests assert the re-export surface
// the loop (U3) imports from @handsoff/intent is intact and behaves identically.
describe("intent tool-risk re-export", () => {
  it("exposes riskForToolCall classifying read-only vs commit", () => {
    expect(riskForToolCall("get_accessibility_tree")).toBe("read_only");
    expect(riskForToolCall("type_text")).toBe("reversible");
    expect(riskForToolCall("click", { element: { role: "AXButton", title: "Send" } })).toBe(
      "mutating",
    );
  });

  it("defaults an unknown tool name to gated via riskForToolName", () => {
    expect(riskForToolName("definitely_not_a_tool")).toBe("mutating");
  });

  it("computes effective risk as the max over a mixed call set", () => {
    const calls: { tool: DriverTool }[] = [{ tool: "get_window_state" }, { tool: "kill_app" }];
    expect(effectiveToolCallRisk(calls)).toBe("destructive_external");
  });
});
