// Per-tool risk gate for the agentic loop (plan U2 / KD3).
//
// The classification DATA and the pure gate live in `@handsoff/contracts`
// (`tool-risk.ts`) — not here — because BOTH `intent` (this package, the loop's
// reasoning side) and `actions` (the executor's gate side) must key risk off
// the tool name, and the boundary rule forbids `actions` importing `intent`.
// `contracts` is the only package both may import, so the shared vocabulary +
// risk map must live there. This module re-exports it so the loop (U3) can keep
// importing the gate from `@handsoff/intent` as the plan describes, alongside
// the existing `riskForIntent`.
export {
  DRIVER_TOOLS,
  driverToolSchema,
  safeParseDriverTool,
  COMMIT_PATTERNS,
  riskForToolCall,
  riskForToolName,
  effectiveToolCallRisk,
  toolCallRequiresApproval,
  toolCallSchema,
} from "@handsoff/contracts";
export type { DriverTool, ToolCall, ToolCallTarget } from "@handsoff/contracts";
