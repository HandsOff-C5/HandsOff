import type { CuaAgentAction, RiskLevel } from "@handsoff/contracts";

import type { CuaInvoke } from "../tauri-driver";
import { createApprovalController, type ApprovalController } from "../safety/approval-controller";
import { buildCuaAgentTool } from "./ax-brain";
import { createAnthropicBrain } from "./anthropic-brain-adapter";
import { createTauriCuaAgentEnv } from "./ax-env";
import { runCuaEscalation, type CuaEscalationRequest } from "./escalation";
import { createTauriComputerUseClient } from "./tauri-brain-client";
import type { GateDecision, LoopResult } from "./computer-use-loop";

// The live CUA stack, assembled behind one Tauri `invoke`: a reusable brain
// client + the AX agent tool + approval controller, and an `escalate` that runs
// one grounded agent loop per below-threshold request (DoD #5). The agent grounds
// on the active window's AX elements + screenshot and acts by element_index. The
// controller wraps the human-in-the-loop gate; share it with the CuaApprovalPanel
// so the UI can render and resolve pending actions.
export type TauriCuaEscalator = {
  approval: ApprovalController;
  escalate(request: CuaEscalationRequest): Promise<LoopResult>;
};

export function createTauriCuaEscalator(deps: {
  invoke: CuaInvoke;
  approval?: ApprovalController;
  brainCommand?: string;
  model?: string;
  maxTokens?: number;
  maxSteps?: number;
  refreshAfterAction?: boolean;
}): TauriCuaEscalator {
  const approval = deps.approval ?? createApprovalController();
  const client = createTauriComputerUseClient(deps.invoke, deps.brainCommand);
  const tool = buildCuaAgentTool();

  // CUA-3 policy: read-only/reversible actions auto-run; only mutating/destructive
  // ones go to the human approval queue (which the CuaApprovalPanel renders and
  // resolves). The loop classifies the action and hands us the risk.
  const approve = (entry: {
    action: CuaAgentAction;
    risk: RiskLevel;
  }): GateDecision | Promise<GateDecision> =>
    entry.risk === "read_only" || entry.risk === "reversible" ? "allow" : approval.approve(entry);

  return {
    approval,
    escalate(request) {
      // No grounded window → nothing safe to drive. Surface it as blocked rather
      // than letting the agent act against an unknown surface.
      if (!request.target) {
        return Promise.resolve({
          status: "blocked",
          summary:
            "No window was resolved for the pointed-at target; cannot escalate to the agent.",
          transcript: [],
        });
      }

      // A fresh brain + env per run: the brain holds the Anthropic message history
      // for that loop (reusing it would bleed context), and the env is pinned to
      // this request's window target.
      const brain = createAnthropicBrain({
        client,
        tool,
        ...(deps.model ? { model: deps.model } : {}),
        ...(deps.maxTokens !== undefined ? { maxTokens: deps.maxTokens } : {}),
      });
      const env = createTauriCuaAgentEnv({
        invoke: deps.invoke,
        target: request.target,
        ...(deps.refreshAfterAction !== undefined
          ? { refreshAfterAction: deps.refreshAfterAction }
          : {}),
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
