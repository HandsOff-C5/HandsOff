import { describe, expect, it, vi } from "vitest";

import type { ComputerUseRequest } from "./anthropic-brain-adapter";
import { CUA_BRAIN_COMMAND, createTauriComputerUseClient } from "./tauri-brain-client";

const request: ComputerUseRequest = {
  model: "claude-opus-4-8",
  betas: ["computer-use-2025-11-24"],
  tools: [{ type: "computer_20251124" }],
  messages: [{ role: "user", content: [{ type: "text", text: "open Cursor" }] }],
  max_tokens: 1024,
};

describe("createTauriComputerUseClient", () => {
  it("forwards the request to the cua_brain_step command and returns the raw message", async () => {
    const raw = { stop_reason: "end_turn", content: [{ type: "text", text: "done" }] };
    const invoke = vi.fn().mockResolvedValue(raw);
    const client = createTauriComputerUseClient(invoke);

    const result = await client.createMessage(request);

    expect(invoke).toHaveBeenCalledWith(CUA_BRAIN_COMMAND, { request });
    expect(result).toBe(raw);
  });

  it("allows overriding the command name", async () => {
    const invoke = vi.fn().mockResolvedValue({});
    const client = createTauriComputerUseClient(invoke, "custom_brain_step");
    await client.createMessage(request);
    expect(invoke).toHaveBeenCalledWith("custom_brain_step", { request });
  });
});
