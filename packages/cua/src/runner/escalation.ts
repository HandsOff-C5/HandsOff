import {
  runComputerUseLoop,
  type ComputerEnv,
  type ComputerUseBrain,
  type GateDecision,
  type LoopResult,
} from "./computer-use-loop";

// STUB — red phase. The failing test demands the real instruction + orchestrator.
export type CuaReferent = { app: string; title?: string; pointer?: { x: number; y: number } };
export type CuaEscalationRequest = { command: string; referent?: CuaReferent };

export function buildCuaInstruction(req: CuaEscalationRequest): string {
  return req.command ? "" : "";
}

export type RunCuaEscalationArgs = CuaEscalationRequest & {
  brain: ComputerUseBrain;
  env: ComputerEnv;
  approve?: (entry: { action: unknown; risk: unknown }) => Promise<GateDecision> | GateDecision;
  maxSteps?: number;
};

export function runCuaEscalation(args: RunCuaEscalationArgs): Promise<LoopResult> {
  return runComputerUseLoop({ goal: args.command, brain: args.brain, env: args.env });
}
