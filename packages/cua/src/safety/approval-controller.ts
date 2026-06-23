import type { ComputerAction, RiskLevel } from "@handsoff/contracts";

import type { GateDecision } from "../runner/computer-use-loop";

// One action awaiting a human decision, surfaced to the approval UI.
export type PendingApproval = {
  id: string;
  action: ComputerAction;
  risk: RiskLevel;
};

// The human-in-the-loop bridge for the computer-use gate. The loop calls
// `approve(entry)` and awaits the returned promise; the controller parks that
// request as `pending` until a UI calls `resolve(id, decision)`. This turns the
// loop's injected `approve` port into a queue a React panel can render and
// resolve, without the loop or the controller knowing about the framework.
export type ApprovalController = {
  approve(entry: { action: ComputerAction; risk: RiskLevel }): Promise<GateDecision>;
  pending(): readonly PendingApproval[];
  resolve(id: string, decision: GateDecision): void;
  subscribe(listener: () => void): () => void;
};

export function createApprovalController(): ApprovalController {
  throw new Error("not implemented");
}
