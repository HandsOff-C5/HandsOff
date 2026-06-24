import { describe, expect, it } from "vitest";

import { CUA_AGENT_MODEL, CUA_AGENT_TOOL_NAME, buildCuaAgentTool } from "./ax-brain";
import {
  createAnthropicBrain,
  type AnthropicMessage,
  type ComputerUseClient,
  type ComputerUseRequest,
} from "./anthropic-brain-adapter";
import type { LoopEntry } from "./computer-use-loop";

const tool = buildCuaAgentTool();

// A click the model asks for, then an end_turn once it sees the refreshed state.
const clickResponse = {
  stop_reason: "tool_use",
  content: [
    { type: "text", text: "clicking the icon" },
    {
      type: "tool_use",
      id: "tu_1",
      name: CUA_AGENT_TOOL_NAME,
      input: { kind: "click", elementIndex: 6 },
    },
  ],
};
const doneResponse = { stop_reason: "end_turn", content: [{ type: "text", text: "done" }] };

function fakeClient(responses: readonly unknown[]): {
  client: ComputerUseClient;
  requests: ComputerUseRequest[];
} {
  const requests: ComputerUseRequest[] = [];
  let index = 0;
  return {
    requests,
    client: {
      async createMessage(request) {
        requests.push(request);
        const response = responses[index];
        index += 1;
        if (response === undefined) throw new Error("fake client ran out of responses");
        return response;
      },
    },
  };
}

function messageAt(
  requests: readonly ComputerUseRequest[],
  call: number,
  msg: number,
): AnthropicMessage {
  const request = requests[call];
  if (!request) throw new Error(`no request for call ${call}`);
  const message = request.messages[msg];
  if (!message) throw new Error(`no message ${msg} in call ${call}`);
  return message;
}

describe("createAnthropicBrain", () => {
  it("opens the conversation with the goal as a user text message; pinned model, no beta, AX tool", async () => {
    const { client, requests } = fakeClient([clickResponse]);
    const brain = createAnthropicBrain({ client, tool });

    const step = await brain.next({ goal: "open Cursor", transcript: [] });

    expect(step.stopReason).toBe("tool_use");
    expect(step.actions[0]).toMatchObject({
      id: "tu_1",
      action: { kind: "click", elementIndex: 6 },
    });

    const request = requests[0];
    if (!request) throw new Error("expected a request");
    expect(request.model).toBe(CUA_AGENT_MODEL);
    // A custom tool needs no beta header.
    expect(request.betas).toEqual([]);
    expect(request.tools).toEqual([tool]);
    expect(request.messages).toEqual([
      { role: "user", content: [{ type: "text", text: "open Cursor" }] },
    ]);
  });

  it("echoes the assistant turn back and answers it with a tool_result carrying the screenshot", async () => {
    const { client, requests } = fakeClient([clickResponse, doneResponse]);
    const brain = createAnthropicBrain({ client, tool });

    await brain.next({ goal: "open Cursor", transcript: [] });

    // The loop executed the click and recorded a (refreshed) screenshot outcome.
    const transcript: LoopEntry[] = [
      { kind: "assistant", text: "clicking the icon" },
      {
        kind: "action",
        action: { kind: "click", elementIndex: 6 },
        risk: "mutating",
        outcome: { status: "ok", screenshot: "BASE64PNG" },
      },
    ];
    const step = await brain.next({ goal: "open Cursor", transcript });
    expect(step.stopReason).toBe("end_turn");

    // call 2 history: [user goal, assistant(verbatim), user(tool_result)]
    expect(messageAt(requests, 1, 0).role).toBe("user");
    const assistant = messageAt(requests, 1, 1);
    expect(assistant.role).toBe("assistant");
    expect(assistant.content).toEqual(clickResponse.content);

    const toolResultMsg = messageAt(requests, 1, 2);
    expect(toolResultMsg.role).toBe("user");
    const block = toolResultMsg.content[0];
    expect(block).toMatchObject({ type: "tool_result", tool_use_id: "tu_1" });
    const inner = (block?.content as AnthropicContentBlockArray)[0];
    expect(inner).toMatchObject({
      type: "image",
      source: { type: "base64", media_type: "image/png", data: "BASE64PNG" },
    });
  });

  it("marks an errored action's tool_result is_error with the error text", async () => {
    const { client, requests } = fakeClient([clickResponse, doneResponse]);
    const brain = createAnthropicBrain({ client, tool });
    await brain.next({ goal: "g", transcript: [] });

    const transcript: LoopEntry[] = [
      {
        kind: "action",
        action: { kind: "click", elementIndex: 6 },
        risk: "mutating",
        outcome: { status: "error", error: "stale element" },
      },
    ];
    await brain.next({ goal: "g", transcript });

    const block = messageAt(requests, 1, 2).content[0];
    expect(block).toMatchObject({ type: "tool_result", tool_use_id: "tu_1", is_error: true });
    expect((block?.content as AnthropicContentBlockArray)[0]).toMatchObject({
      type: "text",
      text: "stale element",
    });
  });

  it("honors model/betas/maxTokens overrides", async () => {
    const { client, requests } = fakeClient([doneResponse]);
    const brain = createAnthropicBrain({
      client,
      tool,
      model: "claude-sonnet-4-6",
      betas: ["beta-x"],
      maxTokens: 2048,
    });
    await brain.next({ goal: "g", transcript: [] });
    const request = requests[0];
    if (!request) throw new Error("expected a request");
    expect(request.model).toBe("claude-sonnet-4-6");
    expect(request.betas).toContain("beta-x");
    expect(request.max_tokens).toBe(2048);
  });
});

type AnthropicContentBlockArray = readonly Record<string, unknown>[];
