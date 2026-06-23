import type { ApprovalDecision } from "@handsoff/contracts";

export function makeApprovalDecision(
  actionId: string,
  decision: ApprovalDecision["decision"],
  decidedAt = new Date().toISOString(),
): ApprovalDecision {
  return { actionId, decision, decidedAt };
}
