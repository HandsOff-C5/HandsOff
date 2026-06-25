import { describe, expect, it } from "vitest";

import { RISK_LEVELS, riskLevelRequiresApproval, safeParseActionPlan } from "./action-plan";
import type { ActionPlan, ActionTarget } from "./action-plan";

function target(): ActionTarget {
  return {
    surface: {
      id: "surface-1",
      title: "Notes",
      app: "Notes",
      pid: 42,
      windowId: 7,
      availability: "available",
      accessStatus: "accessible",
    },
    elementIndex: 1,
  };
}

function plan(overrides: Partial<ActionPlan> = {}): ActionPlan {
  return {
    id: "plan-1",
    summary: "Click the selected control",
    risk_level: "mutating",
    requires_approval: true,
    target_agent: "cua-driver",
    action_plan: [
      { id: "step-1", kind: "click_element", label: "Click selected control", target: target() },
    ],
    ...overrides,
  };
}

describe("action plan contract", () => {
  it("enumerates the approval risk ladder", () => {
    expect(RISK_LEVELS).toEqual(["read_only", "reversible", "mutating", "destructive_external"]);
  });

  it("requires approval for mutating and destructive or external risks", () => {
    expect(riskLevelRequiresApproval("read_only")).toBe(false);
    expect(riskLevelRequiresApproval("reversible")).toBe(false);
    expect(riskLevelRequiresApproval("mutating")).toBe(true);
    expect(riskLevelRequiresApproval("destructive_external")).toBe(true);
  });

  it("accepts a bounded mutating CUA plan", () => {
    const result = safeParseActionPlan(plan());

    expect(result.success).toBe(true);
  });

  it("accepts destructive or external plans so execution can gate them by approval", () => {
    const result = safeParseActionPlan(
      plan({ risk_level: "destructive_external", requires_approval: true }),
    );

    expect(result.success).toBe(true);
  });

  it("rejects plans whose approval flag conflicts with the risk tier", () => {
    const result = safeParseActionPlan(plan({ risk_level: "mutating", requires_approval: false }));

    expect(result.success).toBe(false);
  });

  it("rejects malformed action steps", () => {
    const result = safeParseActionPlan({
      ...plan(),
      action_plan: [{ id: "step-1", kind: "send_email", label: "Send", target: target() }],
    });

    expect(result.success).toBe(false);
  });

  it("accepts app-launch steps without a target surface", () => {
    const result = safeParseActionPlan(
      plan({
        action_plan: [
          { id: "step-1", kind: "launch_app", label: "Open TextEdit", appName: "TextEdit" },
        ],
      }),
    );

    expect(result.success).toBe(true);
  });

  it("accepts a generic tool_call step over the full driver surface (U3b)", () => {
    const result = safeParseActionPlan(
      plan({
        risk_level: "read_only",
        requires_approval: false,
        action_plan: [
          {
            id: "step-1",
            kind: "tool_call",
            label: "Scroll the list down",
            tool: "scroll",
            args: { pid: 42, window_id: 7, direction: "down", by: "page" },
          },
        ],
      }),
    );

    expect(result.success).toBe(true);
  });

  it("defaults a tool_call step's args to an empty object when omitted", () => {
    const result = safeParseActionPlan(
      plan({
        risk_level: "read_only",
        requires_approval: false,
        action_plan: [
          { id: "step-1", kind: "tool_call", label: "List windows", tool: "list_windows" },
        ],
      }),
    );

    expect(result.success).toBe(true);
    if (result.success) {
      const step = result.data.action_plan[0]!;
      expect(step.kind === "tool_call" && step.args).toEqual({});
    }
  });

  it("rejects a tool_call step whose tool is not on the driver surface", () => {
    // `tool` is the DriverTool enum: an empty or off-surface name fails to parse
    // at the schema boundary, not just at the loop's defense-in-depth check.
    for (const tool of ["", "teleport"]) {
      const result = safeParseActionPlan(
        plan({
          action_plan: [{ id: "step-1", kind: "tool_call", label: "Bad tool", tool, args: {} }],
        }),
      );
      expect(result.success).toBe(false);
    }
  });
});
