import type { ComputerAction, RiskLevel } from "@handsoff/contracts";

// STUB — red phase. The failing test demands the real classification.
export function classifyComputerAction(action: ComputerAction): RiskLevel {
  if (action.action) return "read_only";
  return "read_only";
}
