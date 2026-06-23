import type { ComputerAction, RiskLevel } from "@handsoff/contracts";

import { classifyComputerAction } from "../safety/blast-radius";

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

const DEFAULT_MAX_STEPS = 12;

// The default gate when the host injects no approver: observe-only and
// reversible actions auto-run; anything mutating/destructive is denied, because
// a headless loop with no human in the loop must never commit an unapproved
// mutation. The desktop injects an `approve` that awaits a real approval UI.
function defaultApprove(entry: { risk: RiskLevel }): GateDecision {
  return entry.risk === "read_only" || entry.risk === "reversible" ? "allow" : "deny";
}

// The pure computer-use agent loop. Mirrors the Anthropic sampling loop
// (request -> tool_use -> execute -> tool_result -> repeat until end_turn) but
// with the brain and environment injected as ports, so the control flow,
// safety gate, transcript, and termination are all unit-testable without the
// SDK or a live driver. A host adapter (Rust in-app, or a TS worker) supplies
// the real brain (Claude `computer_20251124`) and env (cua-driver).
export async function runComputerUseLoop(args: RunComputerUseLoopArgs): Promise<LoopResult> {
  const maxSteps = args.maxSteps ?? DEFAULT_MAX_STEPS;
  const approve = args.approve ?? defaultApprove;
  const transcript: LoopEntry[] = [];

  for (let step = 0; step < maxSteps; step += 1) {
    const turn = await args.brain.next({ goal: args.goal, transcript });
    if (turn.text) {
      transcript.push({ kind: "assistant", text: turn.text });
    }

    if (turn.stopReason === "refusal") {
      return { status: "blocked", summary: turn.text || "The model declined to act.", transcript };
    }

    if (turn.actions.length === 0) {
      return { status: "succeeded", summary: turn.text || "Task complete.", transcript };
    }

    for (const toolUse of turn.actions) {
      const risk = classifyComputerAction(toolUse.action);
      const decision = await approve({ action: toolUse.action, risk });
      if (decision === "deny") {
        const reason = `Blocked ${toolUse.action.action} (${risk}) pending approval`;
        transcript.push({ kind: "blocked", action: toolUse.action, risk, reason });
        return { status: "blocked", summary: reason, transcript };
      }

      // Execute, recording the outcome. Errors are fed back through the
      // transcript (the brain reacts next turn) rather than aborting the loop.
      const outcome = await args.env.execute(toolUse.action);
      transcript.push({ kind: "action", action: toolUse.action, risk, outcome });
    }
  }

  return {
    status: "max_steps",
    summary: `Stopped after ${maxSteps} steps without completing the task.`,
    transcript,
  };
}
