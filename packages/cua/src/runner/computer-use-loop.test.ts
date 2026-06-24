import { describe, expect, it, vi } from "vitest";

import type { CuaAgentAction } from "@handsoff/contracts";

import {
  runComputerUseLoop,
  type BrainStep,
  type ComputerEnv,
  type ComputerUseBrain,
} from "./computer-use-loop";

// A brain that replays a fixed script of steps, one per call, then keeps
// returning the last step (used to exercise non-terminating loops).
function scriptedBrain(steps: BrainStep[]): ComputerUseBrain & { calls: number } {
  const brain = {
    calls: 0,
    async next() {
      const step = steps[Math.min(brain.calls, steps.length - 1)];
      brain.calls += 1;
      if (!step) throw new Error("scriptedBrain: empty script");
      return step;
    },
  };
  return brain;
}

const done = (text = "Task complete"): BrainStep => ({ text, actions: [], stopReason: "end_turn" });
const act = (id: string, action: CuaAgentAction): BrainStep => ({
  text: "",
  actions: [{ id, action }],
  stopReason: "tool_use",
});

function okEnv(screenshot = "shot"): ComputerEnv & { executed: CuaAgentAction[] } {
  const executed: CuaAgentAction[] = [];
  return {
    executed,
    async execute(action) {
      executed.push(action);
      return { status: "ok", screenshot };
    },
  };
}

describe("computer-use agent loop", () => {
  it("succeeds immediately when the brain returns no actions", async () => {
    const env = okEnv();
    const result = await runComputerUseLoop({
      goal: "do nothing",
      brain: scriptedBrain([done("Nothing to do")]),
      env,
    });

    expect(result.status).toBe("succeeded");
    expect(result.summary).toBe("Nothing to do");
    expect(env.executed).toEqual([]);
  });

  it("runs an observe-only action then finishes (default gate auto-runs read_only)", async () => {
    const env = okEnv();
    const result = await runComputerUseLoop({
      goal: "look",
      brain: scriptedBrain([act("t1", { kind: "snapshot" }), done()]),
      env,
    });

    expect(result.status).toBe("succeeded");
    expect(env.executed).toEqual([{ kind: "snapshot" }]);
    expect(result.transcript.filter((e) => e.kind === "action")).toHaveLength(1);
  });

  it("blocks a mutating action under the default gate without executing it", async () => {
    const env = okEnv();
    const result = await runComputerUseLoop({
      goal: "click",
      brain: scriptedBrain([act("t1", { kind: "click", elementIndex: 5 }), done()]),
      env,
    });

    expect(result.status).toBe("blocked");
    expect(env.executed).toEqual([]); // never ran the unapproved mutation
    expect(result.transcript.at(-1)).toMatchObject({ kind: "blocked", risk: "mutating" });
  });

  it("runs a mutating action when an injected approver allows it", async () => {
    const env = okEnv();
    const approve = vi.fn().mockResolvedValue("allow");
    const result = await runComputerUseLoop({
      goal: "click",
      brain: scriptedBrain([act("t1", { kind: "click", elementIndex: 5 }), done()]),
      env,
      approve,
    });

    expect(result.status).toBe("succeeded");
    expect(env.executed).toEqual([{ kind: "click", elementIndex: 5 }]);
    expect(approve).toHaveBeenCalledWith(
      expect.objectContaining({
        risk: "mutating",
        action: { kind: "click", elementIndex: 5 },
      }),
    );
  });

  it("reports blocked on a model refusal", async () => {
    const env = okEnv();
    const result = await runComputerUseLoop({
      goal: "something disallowed",
      brain: scriptedBrain([
        { text: "I can't help with that.", actions: [], stopReason: "refusal" },
      ]),
      env,
    });

    expect(result.status).toBe("blocked");
    expect(result.summary).toContain("can't help");
  });

  it("stops at maxSteps when the brain never finishes", async () => {
    const env = okEnv();
    const brain = scriptedBrain([act("t1", { kind: "snapshot" })]); // always wants another shot
    const result = await runComputerUseLoop({ goal: "loop", brain, env, maxSteps: 3 });

    expect(result.status).toBe("max_steps");
    expect(brain.calls).toBe(3);
  });

  it("feeds an action error back into the transcript and lets the brain recover", async () => {
    const failing: ComputerEnv = {
      async execute() {
        return { status: "error", error: "display locked" };
      },
    };
    const result = await runComputerUseLoop({
      goal: "screenshot that fails",
      brain: scriptedBrain([act("t1", { kind: "snapshot" }), done("recovered")]),
      env: failing,
    });

    expect(result.status).toBe("succeeded");
    expect(result.summary).toBe("recovered");
    expect(result.transcript).toContainEqual(
      expect.objectContaining({
        kind: "action",
        outcome: { status: "error", error: "display locked" },
      }),
    );
  });
});
