import {
  riskForToolName,
  riskLevelRequiresApproval,
  safeParseDriverTool,
  type ActionStep,
  type CuaActionResult,
  type DriverTool,
  type GoalLoopObservation,
  type ResolvedIntent,
  type RiskLevel,
  type ToolCallTarget,
} from "@handsoff/contracts";

import { gateToolCall } from "./gate-tool-call";

// Pure, React-free step -> tool / risk / dispatch helpers for the autonomous
// loop. They translate an `ActionStep` (the 6 legacy kinds + the full-surface
// `tool_call`) into the driver tool name, risk-relevant target, and the flat
// (tool, args) the generic `driver.call` passthrough (U1) executes — and gate a
// tick against the U2 per-call approval rule. Kept here in `@handsoff/actions`
// (next to the gate) because they are actions-layer execution logic, not React;
// the controller composes them with the live driver.

type ReadyIntent = Extract<ResolvedIntent, { status: "ready" }>;

// Driver tools that click an element (and so get commit-pattern escalation).
const CLICK_TOOLS: ReadonlySet<string> = new Set(["click", "right_click", "double_click"]);

// The driver tool each ActionStep dispatches as. For the full-surface
// `tool_call` step (U3b) this is the tool the model chose verbatim; the legacy
// 6 kinds map to their driver tool so the rule resolver + tests still gate on
// the same vocabulary. Used to key per-call risk (U2).
export function driverToolForStep(step: ActionStep): DriverTool {
  switch (step.kind) {
    case "tool_call": {
      const parsed = safeParseDriverTool(step.tool);
      // An unknown tool name can't be a DriverTool; gate it as the most
      // dangerous via riskForToolName at the call site. Here we surface the
      // closest safe placeholder for the (string) tool name.
      return parsed.success ? parsed.data : "get_window_state";
    }
    case "click_element":
      return "click";
    case "type_text":
      return "type_text";
    case "set_value":
      return "set_value";
    case "launch_app":
      return "launch_app";
    // inspect_window_state / capture_screenshot are read-only perception.
    default:
      return "get_window_state";
  }
}

// The raw tool name a step calls (string — may be outside DRIVER_TOOLS for a
// hallucinated `tool_call`, which `riskForToolName` then gates as mutating).
export function toolNameForStep(step: ActionStep): string {
  return step.kind === "tool_call" ? step.tool : driverToolForStep(step);
}

// The element index a step targets, from its typed target (legacy kinds) or its
// raw driver args (`element_index`, full-surface tool_call).
export function elementIndexForStep(step: ActionStep): number | undefined {
  if (step.kind === "tool_call") {
    const index = step.args["element_index"];
    return typeof index === "number" ? index : undefined;
  }
  if ("target" in step) return step.target.elementIndex;
  return undefined;
}

// Build the risk-relevant target for a click-ish step from the latest snapshot:
// look the element up by index in the perceived AX elements so `riskForToolCall`
// can escalate a *commit* click (Send/Delete/…) to mutating while leaving plain
// navigation clicks free. Only clicks get a target (keys/scroll/etc. carry their
// own risk); absent element metadata leaves the gate to its safe default.
export function toolCallTargetForStep(
  step: ActionStep,
  observation: GoalLoopObservation | undefined,
): ToolCallTarget | undefined {
  const tool = toolNameForStep(step);
  if (!CLICK_TOOLS.has(tool)) return undefined;
  const index = elementIndexForStep(step);
  if (index === undefined) return undefined;
  const element = observation?.state?.elements.find((candidate) => candidate.index === index);
  if (!element) return undefined;
  return {
    element: {
      ...(element.role !== undefined && { role: element.role }),
      ...(element.label !== undefined && { title: element.label, label: element.label }),
      ...(element.value !== undefined && { value: element.value }),
    },
  };
}

// Map any ActionStep to the (tool, args) the generic driver passthrough
// (`driver.call`, U1) executes. The full-surface `tool_call` passes its args
// straight through (the driver's own flat snake_case shape). The legacy 6 kinds
// are translated to flat args from their ActionTarget's surface pid/windowId so
// the rule-resolver path also flows through the single passthrough executor.
export function driverCallForStep(step: ActionStep): {
  tool: string;
  args: Record<string, unknown>;
} {
  if (step.kind === "tool_call") {
    return { tool: step.tool, args: step.args };
  }
  if (step.kind === "launch_app") {
    return {
      tool: "launch_app",
      args: { app_name: step.appName, ...(step.bundleId ? { bundle_id: step.bundleId } : {}) },
    };
  }
  const surface = step.target.surface;
  const base: Record<string, unknown> = {
    ...(surface.pid !== undefined ? { pid: surface.pid } : {}),
    ...(surface.windowId !== undefined ? { window_id: surface.windowId } : {}),
    ...(step.target.elementIndex !== undefined ? { element_index: step.target.elementIndex } : {}),
  };
  switch (step.kind) {
    case "click_element":
      return { tool: "click", args: base };
    case "type_text":
      return { tool: "type_text", args: { ...base, text: step.text } };
    case "set_value":
      return { tool: "set_value", args: { ...base, value: step.value } };
    // inspect_window_state / capture_screenshot → a read-only window probe.
    default:
      return { tool: "get_window_state", args: base };
  }
}

const RISK_RANK: Record<RiskLevel, number> = {
  read_only: 0,
  reversible: 1,
  mutating: 2,
  destructive_external: 3,
};

export function maxRisk(a: RiskLevel, b: RiskLevel): RiskLevel {
  return RISK_RANK[b] > RISK_RANK[a] ? b : a;
}

// The effective risk of a whole one-action-per-tick plan. Risk is the MAX over:
//   - each step's tool-derived risk (U2 `riskForToolCall`, with click element
//     semantics escalating a commit click — Send/Delete/… — to mutating), and
//   - the plan's declared `risk_level`.
// Taking the max means the gate can ESCALATE but the model can never DOWNGRADE
// below what its own tool risk implies (KD3's anti-bypass rule): a model that
// labels a Send click read_only is still gated, while a model that knows a step
// is mutating keeps it gated even when the element label looks benign. The
// per-step max also gates a tick that mixes a free launch with a commit click.
export function planToolRisk(
  plan: ReadyIntent["action_plan"],
  observation: GoalLoopObservation | undefined,
): RiskLevel {
  return plan.action_plan.reduce<RiskLevel>((max, step) => {
    // riskForToolName (not riskForToolCall) so a hallucinated full-surface tool
    // name is gated as mutating rather than throwing — the safe default.
    const risk = riskForToolName(toolNameForStep(step), toolCallTargetForStep(step, observation));
    return maxRisk(max, risk);
  }, plan.risk_level);
}

// Stamp the gate's effective (possibly escalated) risk onto the ready intent so
// the displayed plan + the approval surface agree with the loop's pause: a
// model-declared reversible click on a commit control becomes a mutating plan
// that visibly requires approval. Immutable — returns a new intent.
export function withEffectiveRisk(intent: ReadyIntent, risk: RiskLevel): ReadyIntent {
  if (risk === intent.risk_level) return intent;
  const requires = riskLevelRequiresApproval(risk);
  return {
    ...intent,
    risk_level: risk,
    requires_approval: requires,
    action_plan: {
      ...intent.action_plan,
      risk_level: risk,
      requires_approval: requires,
    },
  };
}

// Run every step through the U2 per-call gate; return the first blocked result
// if any step needs an approval it doesn't have, else null. The gate is derived
// from the tool + target (driverToolForStep already maps a hallucinated
// full-surface tool to the safe get_window_state placeholder; such a step is
// blocked upstream by the resolver), never the model's claim, so a commit step
// (Send/Delete/…) blocks when unapproved.
export function firstBlockedStep(
  steps: readonly ActionStep[],
  observation: GoalLoopObservation | undefined,
  approved: boolean,
): Extract<CuaActionResult, { status: "blocked" }> | null {
  for (const step of steps) {
    const tool = driverToolForStep(step);
    const target = toolCallTargetForStep(step, observation);
    const gate = gateToolCall({ tool, ...(target ? { target } : {}), approved });
    if (!gate.allowed) return gate.result;
  }
  return null;
}
