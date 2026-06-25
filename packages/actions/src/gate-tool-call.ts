import { riskForToolCall, riskLevelRequiresApproval } from "@handsoff/contracts";
import type { CuaActionResult, DriverTool, RiskLevel, ToolCallTarget } from "@handsoff/contracts";

// Per-call gate for the agentic loop (U3 wires this in; this unit only provides
// the pure helper). Keyed on a single tool call: the gate is DERIVED from the
// tool's risk (via `riskForToolCall`) and NEVER from a model-supplied claim, so
// a model that labels a `click` on "Send" as read_only cannot bypass approval.
//
// `allowed` is true when the call may run now: either its risk auto-runs
// (read_only/reversible) or a matching approval has been granted. When blocked,
// `result` carries a typed `blocked` CuaActionResult so the loop can audit it
// identically to any other dispatched call.
export type ToolCallGateResult =
  | { allowed: true; risk: RiskLevel }
  | { allowed: false; risk: RiskLevel; result: Extract<CuaActionResult, { status: "blocked" }> };

export function gateToolCall(args: {
  tool: DriverTool;
  target?: ToolCallTarget;
  approved?: boolean;
}): ToolCallGateResult {
  const risk = riskForToolCall(args.tool, args.target);
  if (!riskLevelRequiresApproval(risk)) return { allowed: true, risk };
  if (args.approved) return { allowed: true, risk };
  return {
    allowed: false,
    risk,
    result: {
      status: "blocked",
      reason: `Approval required before executing ${riskLabel(risk)} tool ${args.tool}`,
    },
  };
}

function riskLabel(risk: RiskLevel): string {
  return risk === "destructive_external" ? "destructive/external" : risk;
}
