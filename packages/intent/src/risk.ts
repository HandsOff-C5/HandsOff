import type { IntentType, RiskLevel } from "@handsoff/contracts";

export function riskForIntent(intentType: IntentType): RiskLevel {
  if (intentType === "inspect" || intentType === "pause" || intentType === "stop") {
    return "read_only";
  }
  // Launching/foregrounding an app is reversible (quit it) — not a mutation of
  // document/data state, so it sits below the click/type/set_value tier.
  if (intentType === "launch") {
    return "reversible";
  }
  return "mutating";
}

export function requiresApproval(riskLevel: RiskLevel): boolean {
  return riskLevel === "mutating" || riskLevel === "destructive";
}
