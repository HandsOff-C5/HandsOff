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
  return { kind: "screenshot", target: step.target };
}

export function translatePlan(plan: ActionPlan): readonly CuaActionRequest[] {
  return plan.action_plan.map(translateStep);
}
