import { describe, expect, it } from "vitest";

import {
  COMPUTER_USE_BETA,
  COMPUTER_USE_MODEL,
  buildComputerUseTool,
  parseBrainStep,
} from "./anthropic-brain";

describe("buildComputerUseTool", () => {
  it("builds the computer_20251124 tool definition with the display geometry", () => {
    expect(buildComputerUseTool({ widthPx: 1512, heightPx: 982 })).toEqual({
      type: "computer_20251124",
      name: "computer",
      display_width_px: 1512,
      display_height_px: 982,
    });
  });

  it("includes display number and zoom when requested", () => {
    expect(
      buildComputerUseTool({ widthPx: 1024, heightPx: 768, displayNumber: 1, enableZoom: true }),
    ).toEqual({
      type: "computer_20251124",
      name: "computer",
      display_width_px: 1024,
      display_height_px: 768,
      display_number: 1,
      enable_zoom: true,
    });
  });

  it("pins the demo model and the current beta header", () => {
    expect(COMPUTER_USE_MODEL).toBe("claude-opus-4-8");
    expect(COMPUTER_USE_BETA).toBe("computer-use-2025-11-24");
  });
});

describe("parseBrainStep", () => {
  it("collects narration text and finishes when there is no tool use", () => {
    const step = parseBrainStep({
      stop_reason: "end_turn",
      content: [{ type: "text", text: "All done." }],
    });
    expect(step).toEqual({ text: "All done.", actions: [], stopReason: "end_turn" });
  });

  it("extracts computer tool_use blocks as validated actions", () => {
    const step = parseBrainStep({
      stop_reason: "tool_use",
      content: [
        { type: "text", text: "Clicking the icon." },
        {
          type: "tool_use",
          id: "toolu_1",
          name: "computer",
          input: { action: "left_click", coordinate: [10, 20] },
        },
      ],
    });
    expect(step.stopReason).toBe("tool_use");
    expect(step.text).toBe("Clicking the icon.");
    expect(step.actions).toEqual([
      { id: "toolu_1", action: { action: "left_click", coordinate: [10, 20] } },
    ]);
  });

  it("derives tool_use stopReason whenever a computer action is present", () => {
    // Even if the API reported max_tokens, an action still needs running.
    const step = parseBrainStep({
      stop_reason: "max_tokens",
      content: [{ type: "tool_use", id: "t", name: "computer", input: { action: "screenshot" } }],
    });
    expect(step.stopReason).toBe("tool_use");
  });

  it("maps a refusal stop reason with empty content", () => {
    const step = parseBrainStep({ stop_reason: "refusal", content: [] });
    expect(step.stopReason).toBe("refusal");
  });

  it("throws on a computer tool_use whose input is not a valid action", () => {
    expect(() =>
      parseBrainStep({
        stop_reason: "tool_use",
        content: [{ type: "tool_use", id: "t", name: "computer", input: { action: "teleport" } }],
      }),
    ).toThrow();
  });

  it("throws on an unsupported (non-computer) tool", () => {
    expect(() =>
      parseBrainStep({
        stop_reason: "tool_use",
        content: [{ type: "tool_use", id: "t", name: "bash", input: { command: "ls" } }],
      }),
    ).toThrow();
  });
});
