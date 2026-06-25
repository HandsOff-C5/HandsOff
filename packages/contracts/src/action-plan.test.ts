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
});
