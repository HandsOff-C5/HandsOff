import { describe, expect, it, vi } from "vitest";

import type { AnthropicMessage } from "./anthropic-brain-adapter";
import { createTauriCuaEscalator } from "./live-cua";

const display = { widthPx: 1440, heightPx: 900 };

const screenshotTurn = {
  stop_reason: "tool_use",
  content: [
    { type: "text", text: "taking a look" },
    { type: "tool_use", id: "tu_1", name: "computer", input: { action: "screenshot" } },
  ],
};
const clickTurn = {
  stop_reason: "tool_use",
  content: [
    {
      type: "tool_use",
      id: "tu_2",
      name: "computer",
      input: { action: "left_click", coordinate: [7, 8] },
    },
  ],
};
const doneTurn = { stop_reason: "end_turn", content: [{ type: "text", text: "done" }] };

type Call = { command: string; args?: Record<string, unknown> };

function fakeInvoke(handlers: Record<string, () => unknown>): {
  invoke: ReturnType<typeof vi.fn>;
  calls: Call[];
} {
  const calls: Call[] = [];
  const invoke = vi.fn().mockImplementation((command: string, args?: Record<string, unknown>) => {
    calls.push({ command, args });
    const handler = handlers[command];
    if (!handler) return Promise.reject(new Error(`no handler for ${command}`));
    return Promise.resolve(handler());
  });
  return { invoke, calls };
}

function brainRequestMessages(call: Call): readonly AnthropicMessage[] {
  const request = call.args?.request as { messages?: readonly AnthropicMessage[] } | undefined;
  if (!request?.messages) throw new Error("expected a brain request with messages");
  return request.messages;
}

describe("createTauriCuaEscalator", () => {
  it("composes the stack and runs a grounded loop to success on end_turn", async () => {
    const { invoke, calls } = fakeInvoke({ cua_brain_step: () => doneTurn });
    const escalator = createTauriCuaEscalator({ invoke, display });

    const result = await escalator.escalate({
      command: "open Cursor",
      referent: { app: "Cursor" },
    });

    expect(result.status).toBe("succeeded");
    const brainCall = calls.find((c) => c.command === "cua_brain_step");
    if (!brainCall) throw new Error("expected a cua_brain_step call");
    // The goal carries the spoken command + the grounded referent.
    const firstUser = brainRequestMessages(brainCall)[0];
    const goal = (firstUser?.content[0] as { text?: string } | undefined)?.text ?? "";
    expect(goal).toContain("open Cursor");
    expect(goal).toContain("Cursor window");
  });

  it("runs a read-only action through the env and feeds the result back (brain↔env↔brain)", async () => {
    let turn = 0;
    const turns = [screenshotTurn, doneTurn];
    const { invoke, calls } = fakeInvoke({
      cua_brain_step: () => turns[turn++],
      cua_screenshot: () => "BASE64PNG",
    });
    const escalator = createTauriCuaEscalator({ invoke, display });

    const result = await escalator.escalate({ command: "open Cursor" });

    expect(result.status).toBe("succeeded");
    // screenshot is read_only → auto-approved → env invoked, then a second brain turn.
    expect(calls.map((c) => c.command)).toEqual([
      "cua_brain_step",
      "cua_screenshot",
      "cua_brain_step",
    ]);
  });

  it("uses a fresh brain per escalate so history does not bleed between requests", async () => {
    const { invoke, calls } = fakeInvoke({ cua_brain_step: () => doneTurn });
    const escalator = createTauriCuaEscalator({ invoke, display });

    await escalator.escalate({ command: "first" });
    await escalator.escalate({ command: "second" });

    const brainCalls = calls.filter((c) => c.command === "cua_brain_step");
    expect(brainCalls).toHaveLength(2);
    const [firstRun, secondRun] = brainCalls;
    if (!firstRun || !secondRun) throw new Error("expected two brain calls");
    // Each run opens with exactly one user message (the goal) — no carry-over.
    expect(brainRequestMessages(firstRun)).toHaveLength(1);
    expect(brainRequestMessages(secondRun)).toHaveLength(1);
  });

  it("queues a mutating action for human approval and proceeds once allowed", async () => {
    let turn = 0;
    const turns = [clickTurn, doneTurn];
    const { invoke, calls } = fakeInvoke({
      cua_brain_step: () => turns[turn++],
      cua_pointer_click: () => undefined,
    });
    const escalator = createTauriCuaEscalator({ invoke, display });

    const runPromise = escalator.escalate({ command: "click OK" });
    await vi.waitFor(() => expect(escalator.approval.pending()).toHaveLength(1));
    const pendingId = escalator.approval.pending()[0]?.id;
    if (!pendingId) throw new Error("expected a pending approval");
    escalator.approval.resolve(pendingId, "allow");

    const result = await runPromise;
    expect(result.status).toBe("succeeded");
    expect(calls.map((c) => c.command)).toContain("cua_pointer_click");
  });

  it("exposes a shared approval controller for the UI", () => {
    const { invoke } = fakeInvoke({ cua_brain_step: () => doneTurn });
    const escalator = createTauriCuaEscalator({ invoke, display });
    expect(escalator.approval.pending()).toEqual([]);
    expect(typeof escalator.approval.subscribe).toBe("function");
  });
});
