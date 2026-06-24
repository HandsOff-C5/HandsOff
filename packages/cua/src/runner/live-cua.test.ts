import { describe, expect, it, vi } from "vitest";

import { CUA_AGENT_TOOL_NAME } from "./ax-brain";
import type { AnthropicMessage } from "./anthropic-brain-adapter";
import { createTauriCuaEscalator } from "./live-cua";

const target = { pid: 85545, windowId: 5833 };

const windowState = {
  surface: {
    id: "1",
    title: "Cursor",
    app: "Cursor",
    availability: "available",
    accessStatus: "accessible",
  },
  capturedAt: "2026-06-22T12:00:00.000Z",
  elementCount: 1,
  elements: [{ id: "a", index: 7, role: "AXButton", label: "OK" }],
  screenshot: { pngBase64: "BASE64PNG", mimeType: "image/png", width: 230, height: 408 },
};

const snapshotTurn = {
  stop_reason: "tool_use",
  content: [
    { type: "text", text: "taking a look" },
    { type: "tool_use", id: "tu_1", name: CUA_AGENT_TOOL_NAME, input: { kind: "snapshot" } },
  ],
};
const clickTurn = {
  stop_reason: "tool_use",
  content: [
    {
      type: "tool_use",
      id: "tu_2",
      name: CUA_AGENT_TOOL_NAME,
      input: { kind: "click", elementIndex: 7 },
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
    const escalator = createTauriCuaEscalator({ invoke });

    const result = await escalator.escalate({
      command: "open Cursor",
      referent: { app: "Cursor" },
      target,
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

  it("blocks when no window target was resolved for the referent", async () => {
    const { invoke, calls } = fakeInvoke({ cua_brain_step: () => doneTurn });
    const escalator = createTauriCuaEscalator({ invoke });

    const result = await escalator.escalate({ command: "click that" });

    expect(result.status).toBe("blocked");
    expect(calls).toEqual([]); // never reached the brain or driver
  });

  it("runs a read-only snapshot through the env and feeds the result back (brain↔env↔brain)", async () => {
    let turn = 0;
    const turns = [snapshotTurn, doneTurn];
    const { invoke, calls } = fakeInvoke({
      cua_brain_step: () => turns[turn++],
      cua_get_window_state: () => windowState,
    });
    const escalator = createTauriCuaEscalator({ invoke });

    const result = await escalator.escalate({ command: "open Cursor", target });

    expect(result.status).toBe("succeeded");
    // snapshot is read_only → auto-approved → env reads state, then a second brain turn.
    expect(calls.map((c) => c.command)).toEqual([
      "cua_brain_step",
      "cua_get_window_state",
      "cua_brain_step",
    ]);
  });

  it("uses a fresh brain per escalate so history does not bleed between requests", async () => {
    const { invoke, calls } = fakeInvoke({ cua_brain_step: () => doneTurn });
    const escalator = createTauriCuaEscalator({ invoke });

    await escalator.escalate({ command: "first", target });
    await escalator.escalate({ command: "second", target });

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
      cua_click: () => undefined,
      cua_get_window_state: () => windowState, // the auto-refresh after the click
    });
    const escalator = createTauriCuaEscalator({ invoke });

    const runPromise = escalator.escalate({ command: "click OK", target });
    await vi.waitFor(() => expect(escalator.approval.pending()).toHaveLength(1));
    const pendingId = escalator.approval.pending()[0]?.id;
    if (!pendingId) throw new Error("expected a pending approval");
    escalator.approval.resolve(pendingId, "allow");

    const result = await runPromise;
    expect(result.status).toBe("succeeded");
    expect(calls.map((c) => c.command)).toContain("cua_click");
  });

  it("exposes a shared approval controller for the UI", () => {
    const { invoke } = fakeInvoke({ cua_brain_step: () => doneTurn });
    const escalator = createTauriCuaEscalator({ invoke });
    expect(escalator.approval.pending()).toEqual([]);
    expect(typeof escalator.approval.subscribe).toBe("function");
  });
});
