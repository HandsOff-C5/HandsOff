import type { CuaAgentAction, RiskLevel } from "@handsoff/contracts";

import {
  runComputerUseLoop,
  type ComputerEnv,
  type ComputerUseBrain,
  type GateDecision,
  type LoopResult,
} from "./computer-use-loop";
import type { CuaAgentTarget } from "./ax-env";

// What the user pointed at, resolved by fusion/perception — injected into the
// brain's goal so the agent starts grounded instead of hunting the whole screen.
export type CuaReferent = { app: string; title?: string; pointer?: { x: number; y: number } };

// The concrete window the agent operates within (`CuaAgentTarget`, from ax-env)
// is resolved upstream from the referent. Optional so a request can fall back to
// the host-resolved active window when perception couldn't pin one.
export type CuaEscalationRequest = {
  command: string;
  referent?: CuaReferent;
  target?: CuaAgentTarget;
};

// Build the computer-use goal for an escalated request. The research is explicit
// that a pixel-only agent's native ceiling is low and that the *pointed-at
// referent is what lifts it* — so when fusion resolved a referent we name it (and
// its rough screen location) up front, then instruct the screenshot-first,
// verify-each-step discipline the computer-use docs recommend.
export function buildCuaInstruction(req: CuaEscalationRequest): string {
  const lines = [`The user said: "${req.command}".`];

  if (req.referent) {
    const title = req.referent.title ? ` titled "${req.referent.title}"` : "";
    const where = req.referent.pointer
      ? ` near screen point (${req.referent.pointer.x}, ${req.referent.pointer.y})`
      : "";
    lines.push(`They pointed at the ${req.referent.app} window${title}${where}.`);
  }

  lines.push(
    "Complete the request by operating the active window. Take a snapshot first to read its " +
      "elements, act by elementIndex, and after each step re-check the snapshot to verify the " +
      "result before continuing.",
  );

  return lines.join(" ");
}

export type RunCuaEscalationArgs = CuaEscalationRequest & {
  brain: ComputerUseBrain;
  env: ComputerEnv;
  approve?: (entry: {
    action: CuaAgentAction;
    risk: RiskLevel;
  }) => Promise<GateDecision> | GateDecision;
  maxSteps?: number;
};

// Run the computer-use loop for a below-threshold / ambiguous request, with the
// referent-grounded instruction as the goal. The brain (live Claude call) and
// env (cua-driver) are injected; the safety gate and termination come from the
// loop. This is the DoD #5 escalation path.
export function runCuaEscalation(args: RunCuaEscalationArgs): Promise<LoopResult> {
  return runComputerUseLoop({
    goal: buildCuaInstruction({ command: args.command, referent: args.referent }),
    brain: args.brain,
    env: args.env,
    approve: args.approve,
    maxSteps: args.maxSteps,
  });
}
