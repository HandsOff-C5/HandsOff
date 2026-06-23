import type { ComputerAction, RiskLevel } from "@handsoff/contracts";

// One computer-use tool call the brain wants to run, carrying the model's
// tool_use id so a host adapter can pair it with the tool_result it sends back.
export type BrainToolUse = { id: string; action: ComputerAction };

// The brain's decision for one turn of the loop, abstracted from the Anthropic
// SDK. `actions` empty + stopReason "end_turn" => the task is complete.
export type BrainStep = {
  text: string;
  actions: readonly BrainToolUse[];
  stopReason: "tool_use" | "end_turn" | "refusal";
};

export type ComputerUseBrain = {
  next(input: { goal: string; transcript: readonly LoopEntry[] }): Promise<BrainStep>;
};

// The outcome of executing one action. A successful action may return a fresh
// screenshot to feed the next turn; an error is fed back (is_error) so the
// brain can react rather than the loop hard-aborting.
export type ActionOutcome =
  | { status: "ok"; screenshot?: string; text?: string }
  | { status: "error"; error: string };

export type ComputerEnv = {
  execute(action: ComputerAction): Promise<ActionOutcome>;
};

export type GateDecision = "allow" | "deny";

export type LoopEntry =
  | { kind: "assistant"; text: string }
  | { kind: "action"; action: ComputerAction; risk: RiskLevel; outcome: ActionOutcome }
  | { kind: "blocked"; action: ComputerAction; risk: RiskLevel; reason: string };

export type LoopStatus = "succeeded" | "blocked" | "failed" | "max_steps";

export type LoopResult = {
  status: LoopStatus;
  summary: string;
  transcript: readonly LoopEntry[];
};

export type RunComputerUseLoopArgs = {
  goal: string;
  brain: ComputerUseBrain;
  env: ComputerEnv;
  approve?: (entry: {
    action: ComputerAction;
    risk: RiskLevel;
  }) => Promise<GateDecision> | GateDecision;
  maxSteps?: number;
};

// STUB — red phase. The failing test demands the real loop.
export async function runComputerUseLoop(args: RunComputerUseLoopArgs): Promise<LoopResult> {
  return { status: "failed", summary: `not implemented: ${args.goal}`, transcript: [] };
}
