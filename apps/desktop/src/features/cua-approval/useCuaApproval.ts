import type { ApprovalController, GateDecision, PendingApproval } from "@handsoff/cua";

export type CuaApproval = {
  pending: readonly PendingApproval[];
  decide: (id: string, decision: GateDecision) => void;
};

export function useCuaApproval(_controller: ApprovalController): CuaApproval {
  void _controller.pending;
  throw new Error("not implemented");
}
