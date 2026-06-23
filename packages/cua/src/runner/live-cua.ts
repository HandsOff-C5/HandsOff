import type { ComputerAction, RiskLevel } from "@handsoff/contracts";

import type { CuaInvoke } from "../tauri-driver";
import { createApprovalController, type ApprovalController } from "../safety/approval-controller";
import { buildComputerUseTool } from "./anthropic-brain";
import { createAnthropicBrain } from "./anthropic-brain-adapter";
import { createTauriComputerEnv } from "./computer-env";
import { runCuaEscalation, type CuaEscalationRequest } from "./escalation";
import { createTauriComputerUseClient } from "./tauri-brain-client";
import type { GateDecision, LoopResult } from "./computer-use-loop";

// The live CUA stack, assembled behind one Tauri `invoke`: a reusable brain
// client + env + approval controller, and an `escalate` that runs one grounded
// computer-use loop per below-threshold request (DoD #5). The controller wraps
// the human-in-the-loop gate; share it with the CuaApprovalPanel so the UI can
// render and resolve pending actions.
export type TauriCuaEscalator = {
  approval: ApprovalController;
  escalate(request: CuaEscalationRequest): Promise<LoopResult>;
};

export function createTauriCuaEscalator(deps: {
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
  const approval = deps.approval ?? createApprovalController();
  const client = createTauriComputerUseClient(deps.invoke, deps.brainCommand);
  const tool = buildComputerUseTool(deps.display);
  const env = createTauriComputerEnv({
    invoke: deps.invoke,
    ...(deps.wait ? { wait: deps.wait } : {}),
  });

  // CUA-3 policy: read-only/reversible actions auto-run; only mutating/destructive
  // ones go to the human approval queue (which the CuaApprovalPanel renders and
  // resolves). The loop classifies the action and hands us the risk.
  const approve = (entry: {
    action: ComputerAction;
    risk: RiskLevel;
  }): GateDecision | Promise<GateDecision> =>
    entry.risk === "read_only" || entry.risk === "reversible" ? "allow" : approval.approve(entry);

  return {
    approval,
    escalate(request) {
      // A fresh brain per run: it holds the Anthropic message history for that
      // loop, so reusing one across requests would bleed context between them.
      const brain = createAnthropicBrain({
        client,
        tool,
        ...(deps.model ? { model: deps.model } : {}),
        ...(deps.beta ? { beta: deps.beta } : {}),
        ...(deps.maxTokens !== undefined ? { maxTokens: deps.maxTokens } : {}),
      });
      return runCuaEscalation({
        ...request,
        brain,
        env,
        approve,
        ...(deps.maxSteps !== undefined ? { maxSteps: deps.maxSteps } : {}),
      });
    },
  };
}
