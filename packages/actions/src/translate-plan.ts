import type { ActionPlan, ActionStep, CuaActionRequest } from "@handsoff/contracts";

export function translateStep(step: ActionStep): CuaActionRequest {
  if (step.kind === "launch_app") {
    return { kind: "launch_app", appName: step.appName, bundleId: step.bundleId };
  }
  if (step.kind === "inspect_window_state") {
    return { kind: "get_window_state", target: step.target };
  }
  if (step.kind === "click_element") {
    return { kind: "click", target: step.target };
  }
  if (step.kind === "type_text") {
    return { kind: "type_text", target: step.target, text: step.text };
  }
  if (step.kind === "set_value") {
    return { kind: "set_value", target: step.target, value: step.value };
  }
  if (step.kind === "capture_screenshot") {
    return { kind: "screenshot", target: step.target };
  }
  // A `tool_call` step (U3b full-surface) is dispatched directly via the generic
  // driver passthrough (`driver.call`), never through this typed translator. It
  // must never reach here; if it does, that is a routing bug, not a screenshot.
  throw new Error(`translateStep cannot translate a generic tool_call step: ${step.tool}`);
}

export function translatePlan(plan: ActionPlan): readonly CuaActionRequest[] {
  return plan.action_plan.map(translateStep);
}
