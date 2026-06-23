import type { CuaInvoke } from "../tauri-driver";
import type { ApprovalController } from "../safety/approval-controller";
import type { CuaEscalationRequest } from "./escalation";
import type { LoopResult } from "./computer-use-loop";

// The live CUA stack, assembled behind one Tauri `invoke`: a reusable brain
// client + env + approval controller, and an `escalate` that runs one grounded
// computer-use loop per below-threshold request (DoD #5). The controller wraps
// the human-in-the-loop gate; share it with the CuaApprovalPanel so the UI can
// render and resolve pending actions.
export type TauriCuaEscalator = {
  approval: ApprovalController;
  escalate(request: CuaEscalationRequest): Promise<LoopResult>;
};

export function createTauriCuaEscalator(_deps: {
  invoke: CuaInvoke;
  display: { widthPx: number; heightPx: number; displayNumber?: number; enableZoom?: boolean };
  approval?: ApprovalController;
  brainCommand?: string;
  model?: string;
  beta?: string;
  maxTokens?: number;
  maxSteps?: number;
  wait?: (ms: number) => Promise<void>;
}): TauriCuaEscalator {
  void _deps.invoke;
  throw new Error("not implemented");
}
