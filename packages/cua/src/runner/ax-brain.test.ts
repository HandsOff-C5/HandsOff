import { describe, expect, it } from "vitest";

import {
  buildCuaAgentTool,
  parseCuaAgentStep,
  CUA_AGENT_MODEL,
  CUA_AGENT_TOOL_NAME,
} from "./ax-brain";

describe("AX agent brain tool + parser", () => {
  it("builds a custom tool (no computer_20251124, no beta) with the action input schema", () => {
    const tool = buildCuaAgentTool();
    expect(tool.name).toBe(CUA_AGENT_TOOL_NAME);
    // A plain custom tool — it must NOT be the pixel computer-use tool type.
    expect(tool.type).toBeUndefined();
    const schema = tool.input_schema as { properties?: Record<string, unknown> };
    expect(schema.properties).toHaveProperty("kind");
    expect(schema.properties).toHaveProperty("elementIndex");
  });

  it("targets Opus 4.8", () => {
    expect(CUA_AGENT_MODEL).toBe("claude-opus-4-8");
  });

  it("parses narration + a validated element-index click into a tool_use step", () => {
    const step = parseCuaAgentStep({
      stop_reason: "tool_use",
      content: [
        { type: "text", text: "Clicking the equals key." },
        {
          type: "tool_use",
          id: "tu_1",
          name: CUA_AGENT_TOOL_NAME,
          input: { kind: "click", elementIndex: 16 },
        },
      ],
    });
    expect(step.text).toBe("Clicking the equals key.");
    expect(step.stopReason).toBe("tool_use");
    expect(step.actions).toEqual([{ id: "tu_1", action: { kind: "click", elementIndex: 16 } }]);
  });

  it("treats a no-tool end_turn as task completion", () => {
    const step = parseCuaAgentStep({
      stop_reason: "end_turn",
      content: [{ type: "text", text: "Done — the result shows 12." }],
    });
    expect(step.actions).toHaveLength(0);
    expect(step.stopReason).toBe("end_turn");
  });

  it("surfaces a refusal with no actions", () => {
    const step = parseCuaAgentStep({
      stop_reason: "refusal",
      content: [{ type: "text", text: "No." }],
    });
    expect(step.stopReason).toBe("refusal");
  });

  it("throws on an unknown tool name", () => {
    expect(() =>
      parseCuaAgentStep({
        stop_reason: "tool_use",
        content: [{ type: "tool_use", id: "x", name: "computer", input: { kind: "snapshot" } }],
      }),
    ).toThrow(/Unsupported tool/);
  });

  it("throws when the model emits an invalid action", () => {
    expect(() =>
      parseCuaAgentStep({
        stop_reason: "tool_use",
        content: [
          {
            type: "tool_use",
            id: "x",
            name: CUA_AGENT_TOOL_NAME,
            input: { kind: "click", elementIndex: -3 },
          },
        ],
      }),
    ).toThrow(/Invalid CUA agent action/);
  });
});
