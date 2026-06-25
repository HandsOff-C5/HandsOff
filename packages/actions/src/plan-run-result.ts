import type { CuaActionResult, ExecutionStatus } from "@handsoff/contracts";

// The terminal result of running one tick's action plan: the execution status
// plus the optional typed driver result that produced it. Surfaced by the
// autonomous loop (`useVoiceCuaController`) as its `runResult` state and rendered
// by the plan-preview panel.
export type PlanRunResult = {
  status: ExecutionStatus;
  result?: CuaActionResult;
};
