import type { IntentType, RiskLevel } from "@handsoff/contracts";

export function riskForIntent(intentType: IntentType): RiskLevel {
  if (intentType === "inspect" || intentType === "pause" || intentType === "stop") {
    return "read_only";
  }
  return "mutating";
}

export function requiresApproval(riskLevel: RiskLevel): boolean {
  return riskLevel === "mutating" || riskLevel === "destructive";
}
