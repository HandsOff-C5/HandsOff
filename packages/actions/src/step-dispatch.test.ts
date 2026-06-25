import type { ActionStep, GoalLoopObservation, ResolvedIntent } from "@handsoff/contracts";
import { fakeActionTarget, fakeCuaWindowState } from "@handsoff/testkit";
import { describe, expect, it } from "vitest";

import {
  driverCallForStep,
  driverToolForStep,
  elementIndexForStep,
  firstBlockedStep,
  maxRisk,
  planToolRisk,
  toolCallTargetForStep,
  toolNameForStep,
  withEffectiveRisk,
} from "./step-dispatch";

type ReadyIntent = Extract<ResolvedIntent, { status: "ready" }>;

// A tool_call step whose `tool` is OFF the driver surface. The schema now types
// `tool` as the DriverTool enum, so such a step cannot pass validation — but the
// defensive helpers (driverToolForStep / toolNameForStep / planToolRisk) still
// guard the raw-model case where an unvalidated tool name reaches them, so we
// construct it with a localized cast to exercise that safe-default path.
function offSurfaceToolCall(tool: string): ActionStep {
  return { id: "1", kind: "tool_call", label: "?", tool, args: {} } as unknown as ActionStep;
}

function readyIntent(
  steps: readonly ActionStep[],
  overrides: Partial<ReadyIntent> = {},
): ReadyIntent {
  const target_agent = "cua-driver" as const;
  const risk_level = overrides.risk_level ?? "reversible";
  return {
    status: "ready",
    id: "intent-1",
    intent_type: "click",
    input: {
      sessionId: "session-1",
      speech: {
        finalTranscript: {
          kind: "final",
          text: "do it",
          confidence: 0.9,
          latencyMs: 0,
          receivedAt: 0,
        },
      },
      pointingEvidence: [],
      surfaceCandidates: [],
    },
    referent: null,
    constraints: [],
    risk_level,
    requires_approval: overrides.requires_approval ?? false,
    target_agent,
    createdAt: "2026-06-22T12:00:00.000Z",
    action_plan: {
      id: "plan-1",
      summary: "Do it",
      risk_level,
      requires_approval: overrides.requires_approval ?? false,
      target_agent,
      action_plan: [...steps],
    },
    ...overrides,
  };
}

// An observation whose perceived AX element at `index` carries `label`, so a
// click target lookup can resolve a commit element (Send/Delete/…).
function observationWithElement(index: number, label: string): GoalLoopObservation {
  return {
    tick: 0,
    capturedAt: "2026-06-22T12:00:00.000Z",
    windows: [],
    state: fakeCuaWindowState({
      elements: [{ id: `element-${index}`, index, role: "AXButton", label }],
    }),
  };
}

describe("driverToolForStep", () => {
  it("passes a full-surface tool_call's verbatim tool name when it is a real driver tool", () => {
    const step: ActionStep = {
      id: "1",
      kind: "tool_call",
      label: "Scroll",
      tool: "scroll",
      args: {},
    };
    expect(driverToolForStep(step)).toBe("scroll");
  });

  it("maps an unknown tool_call name to the safe get_window_state placeholder", () => {
    expect(driverToolForStep(offSurfaceToolCall("teleport"))).toBe("get_window_state");
  });

  it("maps the legacy 6 kinds to their driver tool", () => {
    const target = fakeActionTarget();
    expect(driverToolForStep({ id: "1", kind: "click_element", label: "Click", target })).toBe(
      "click",
    );
    expect(
      driverToolForStep({ id: "2", kind: "type_text", label: "Type", target, text: "hi" }),
    ).toBe("type_text");
    expect(
      driverToolForStep({ id: "3", kind: "set_value", label: "Set", target, value: "x" }),
    ).toBe("set_value");
    expect(
      driverToolForStep({ id: "4", kind: "launch_app", label: "Open", appName: "Notes" }),
    ).toBe("launch_app");
    expect(
      driverToolForStep({ id: "5", kind: "inspect_window_state", label: "Look", target }),
    ).toBe("get_window_state");
    expect(driverToolForStep({ id: "6", kind: "capture_screenshot", label: "Shot", target })).toBe(
      "get_window_state",
    );
  });
});

describe("toolNameForStep", () => {
  it("returns the raw (possibly non-driver) tool string for a tool_call", () => {
    expect(toolNameForStep(offSurfaceToolCall("teleport"))).toBe("teleport");
  });

  it("returns the mapped driver tool for a legacy kind", () => {
    expect(
      toolNameForStep({
        id: "1",
        kind: "click_element",
        label: "Click",
        target: fakeActionTarget(),
      }),
    ).toBe("click");
  });
});

describe("elementIndexForStep", () => {
  it("reads element_index from a tool_call's raw args", () => {
    const step: ActionStep = {
      id: "1",
      kind: "tool_call",
      label: "Click",
      tool: "click",
      args: { element_index: 4 },
    };
    expect(elementIndexForStep(step)).toBe(4);
  });

  it("reads elementIndex from a legacy kind's typed target", () => {
    const target = fakeActionTarget({ elementIndex: 7 });
    expect(elementIndexForStep({ id: "1", kind: "click_element", label: "Click", target })).toBe(7);
  });

  it("returns undefined when no index is present", () => {
    const step: ActionStep = {
      id: "1",
      kind: "tool_call",
      label: "Scroll",
      tool: "scroll",
      args: {},
    };
    expect(elementIndexForStep(step)).toBeUndefined();
  });
});

describe("toolCallTargetForStep", () => {
  it("builds the AX element target for a click by index from the observation", () => {
    const step: ActionStep = {
      id: "1",
      kind: "tool_call",
      label: "Click Send",
      tool: "click",
      args: { element_index: 2 },
    };
    expect(toolCallTargetForStep(step, observationWithElement(2, "Send"))).toEqual({
      element: { role: "AXButton", title: "Send", label: "Send" },
    });
  });

  it("returns undefined for a non-click tool (its own risk applies)", () => {
    const step: ActionStep = {
      id: "1",
      kind: "tool_call",
      label: "Type",
      tool: "type_text",
      args: { element_index: 2, text: "hi" },
    };
    expect(toolCallTargetForStep(step, observationWithElement(2, "Send"))).toBeUndefined();
  });

  it("returns undefined when the element is not in the observation (safe default applies)", () => {
    const step: ActionStep = {
      id: "1",
      kind: "tool_call",
      label: "Click",
      tool: "click",
      args: { element_index: 99 },
    };
    expect(toolCallTargetForStep(step, observationWithElement(2, "Send"))).toBeUndefined();
  });
});

describe("driverCallForStep", () => {
  it("passes a tool_call's flat args straight through", () => {
    const step: ActionStep = {
      id: "1",
      kind: "tool_call",
      label: "Scroll",
      tool: "scroll",
      args: { pid: 42, direction: "down" },
    };
    expect(driverCallForStep(step)).toEqual({
      tool: "scroll",
      args: { pid: 42, direction: "down" },
    });
  });

  it("translates launch_app to snake_case driver args", () => {
    expect(
      driverCallForStep({ id: "1", kind: "launch_app", label: "Open", appName: "Notes" }),
    ).toEqual({ tool: "launch_app", args: { app_name: "Notes" } });
    expect(
      driverCallForStep({
        id: "1",
        kind: "launch_app",
        label: "Open",
        appName: "Notes",
        bundleId: "com.apple.Notes",
      }),
    ).toEqual({ tool: "launch_app", args: { app_name: "Notes", bundle_id: "com.apple.Notes" } });
  });

  it("translates a click_element to flat pid/window_id/element_index from its surface", () => {
    const target = fakeActionTarget({
      surface: {
        id: "win-1",
        title: "Doc",
        app: "TextEdit",
        availability: "available",
        accessStatus: "accessible",
        pid: 7,
        windowId: 3,
      },
      elementIndex: 5,
    });
    expect(driverCallForStep({ id: "1", kind: "click_element", label: "Click", target })).toEqual({
      tool: "click",
      args: { pid: 7, window_id: 3, element_index: 5 },
    });
  });

  it("carries text/value for type_text and set_value", () => {
    const target = fakeActionTarget();
    expect(
      driverCallForStep({ id: "1", kind: "type_text", label: "Type", target, text: "hi" }).args,
    ).toMatchObject({ text: "hi" });
    expect(
      driverCallForStep({ id: "1", kind: "set_value", label: "Set", target, value: "v" }).args,
    ).toMatchObject({ value: "v" });
  });
});

describe("maxRisk", () => {
  it("returns the higher-ranked of two risk levels", () => {
    expect(maxRisk("read_only", "reversible")).toBe("reversible");
    expect(maxRisk("mutating", "reversible")).toBe("mutating");
    expect(maxRisk("mutating", "destructive_external")).toBe("destructive_external");
    expect(maxRisk("read_only", "read_only")).toBe("read_only");
  });
});

describe("planToolRisk", () => {
  it("escalates a commit click (Send) to mutating above a reversible plan", () => {
    const step: ActionStep = {
      id: "1",
      kind: "tool_call",
      label: "Click Send",
      tool: "click",
      args: { element_index: 2 },
    };
    const intent = readyIntent([step], { risk_level: "reversible" });
    expect(planToolRisk(intent.action_plan, observationWithElement(2, "Send"))).toBe("mutating");
  });

  it("keeps a benign navigation click reversible", () => {
    const step: ActionStep = {
      id: "1",
      kind: "tool_call",
      label: "Click Sort",
      tool: "click",
      args: { element_index: 2 },
    };
    const intent = readyIntent([step], { risk_level: "reversible" });
    expect(planToolRisk(intent.action_plan, observationWithElement(2, "Sort by"))).toBe(
      "reversible",
    );
  });

  it("gates a hallucinated tool name as mutating (the safe default)", () => {
    const intent = readyIntent([offSurfaceToolCall("teleport")], { risk_level: "read_only" });
    expect(planToolRisk(intent.action_plan, undefined)).toBe("mutating");
  });
});

describe("withEffectiveRisk", () => {
  it("returns the same intent when the risk is unchanged", () => {
    const intent = readyIntent([], { risk_level: "reversible" });
    expect(withEffectiveRisk(intent, "reversible")).toBe(intent);
  });

  it("stamps an escalated mutating risk onto both the intent and its plan, requiring approval", () => {
    const intent = readyIntent([], { risk_level: "reversible", requires_approval: false });
    const next = withEffectiveRisk(intent, "mutating");
    expect(next.risk_level).toBe("mutating");
    expect(next.requires_approval).toBe(true);
    expect(next.action_plan.risk_level).toBe("mutating");
    expect(next.action_plan.requires_approval).toBe(true);
    // Immutable: the original is untouched.
    expect(intent.risk_level).toBe("reversible");
  });
});

describe("firstBlockedStep", () => {
  const sendClick: ActionStep = {
    id: "1",
    kind: "tool_call",
    label: "Click Send",
    tool: "click",
    args: { element_index: 2 },
  };

  it("blocks an unapproved commit click with a typed blocked result", () => {
    const blocked = firstBlockedStep([sendClick], observationWithElement(2, "Send"), false);
    expect(blocked).toMatchObject({ status: "blocked" });
    expect(blocked?.reason).toContain("Approval required");
  });

  it("allows the same commit click once approved", () => {
    expect(firstBlockedStep([sendClick], observationWithElement(2, "Send"), true)).toBeNull();
  });

  it("allows a read-only / navigation step without approval", () => {
    const scroll: ActionStep = {
      id: "1",
      kind: "tool_call",
      label: "Scroll",
      tool: "scroll",
      args: {},
    };
    expect(firstBlockedStep([scroll], undefined, false)).toBeNull();
  });
});
