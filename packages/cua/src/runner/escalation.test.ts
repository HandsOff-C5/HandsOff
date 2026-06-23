import { describe, expect, it } from "vitest";

import type { ComputerAction } from "@handsoff/contracts";

import type { BrainStep, ComputerEnv, ComputerUseBrain } from "./computer-use-loop";
import { buildCuaInstruction, runCuaEscalation } from "./escalation";

const okEnv: ComputerEnv = {
  async execute() {
    return { status: "ok", screenshot: "shot" };
  },
};

// Captures the goal it was handed, replays a fixed script.
function recordingBrain(steps: BrainStep[]): ComputerUseBrain & { goals: string[] } {
  const brain = {
    goals: [] as string[],
    calls: 0,
    async next(input: { goal: string }) {
      brain.goals.push(input.goal);
      const step = steps[Math.min(brain.calls, steps.length - 1)];
      brain.calls += 1;
      if (!step) throw new Error("empty script");
      return step;
    },
  };
  return brain;
}

const done = (text = "done"): BrainStep => ({ text, actions: [], stopReason: "end_turn" });
const act = (action: ComputerAction): BrainStep => ({
  text: "",
  actions: [{ id: "t", action }],
  stopReason: "tool_use",
});

describe("buildCuaInstruction", () => {
  it("includes the spoken command verbatim", () => {
    const instruction = buildCuaInstruction({ command: "archive this email" });
    expect(instruction).toContain("archive this email");
  });

  it("injects the pointed-at referent (app + title) when present", () => {
    const instruction = buildCuaInstruction({
      command: "rename it",
      referent: { app: "Finder", title: "Reports" },
    });
    expect(instruction).toContain("Finder");
    expect(instruction).toContain("Reports");
  });

  it("injects the pointer coordinate when present", () => {
    const instruction = buildCuaInstruction({
      command: "click that",
      referent: { app: "Safari", pointer: { x: 640, y: 360 } },
    });
    expect(instruction).toMatch(/640/);
    expect(instruction).toMatch(/360/);
  });

  it("still produces a usable instruction with no referent", () => {
    const instruction = buildCuaInstruction({ command: "open settings" });
    expect(instruction).toContain("open settings");
    expect(instruction.toLowerCase()).toContain("screenshot");
  });
});

describe("runCuaEscalation", () => {
  it("hands the built instruction to the brain and returns the loop result", async () => {
    const brain = recordingBrain([done("finished")]);
    const result = await runCuaEscalation({
      command: "tidy the desktop",
      referent: { app: "Finder" },
      brain,
      env: okEnv,
    });

    expect(result.status).toBe("succeeded");
    expect(brain.goals[0]).toContain("tidy the desktop");
    expect(brain.goals[0]).toContain("Finder");
  });

  it("drives the loop end to end (screenshot then finish) with the default gate", async () => {
    const brain = recordingBrain([act({ action: "screenshot" }), done()]);
    const result = await runCuaEscalation({ command: "look around", brain, env: okEnv });

    expect(result.status).toBe("succeeded");
    expect(result.transcript.some((e) => e.kind === "action")).toBe(true);
  });
});
