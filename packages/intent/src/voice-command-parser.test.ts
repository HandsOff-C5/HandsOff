import { describe, expect, it } from "vitest";

import { parseVoiceCommand } from "./voice-command-parser";

describe("voice command parser", () => {
  it("parses the first slice command set", () => {
    expect(parseVoiceCommand("click there")).toEqual({ status: "parsed", intent_type: "click" });
    expect(parseVoiceCommand("type hello into that")).toEqual({
      status: "parsed",
      intent_type: "type_text",
      text: "hello",
    });
    expect(parseVoiceCommand("inspect this window")).toEqual({
      status: "parsed",
      intent_type: "inspect",
    });
  });

  it("blocks unsupported commands", () => {
    expect(parseVoiceCommand("send it")).toEqual({
      status: "unsupported",
      reason: "Unsupported voice command",
    });
  });
});
