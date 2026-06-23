import type { ApprovalController, GateDecision, PendingApproval } from "@handsoff/cua";
import { useEffect, useState } from "react";

export type CuaApproval = {
  pending: readonly PendingApproval[];
  decide: (id: string, decision: GateDecision) => void;
};

// Bridges the cua ApprovalController (a framework-free promise queue) to React:
// subscribes so the panel re-renders whenever the agent loop queues or a human
// resolves an approval. `decide` settles the loop's awaited promise. Inject
// `controller.approve` into runComputerUseLoop and render `pending` in the panel.
export function useCuaApproval(controller: ApprovalController): CuaApproval {
  const [pending, setPending] = useState<readonly PendingApproval[]>(() => controller.pending());

  useEffect(() => {
    setPending(controller.pending());
    return controller.subscribe(() => setPending(controller.pending()));
  }, [controller]);

  return { pending, decide: controller.resolve };
}
