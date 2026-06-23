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

  it("parses a bare open/launch command into a launch with the app name", () => {
    expect(parseVoiceCommand("open Cursor")).toEqual({
      status: "parsed",
      intent_type: "launch",
      appName: "Cursor",
    });
    expect(parseVoiceCommand("launch Safari")).toEqual({
      status: "parsed",
      intent_type: "launch",
      appName: "Safari",
    });
  });

  it("still routes open-and-type to a type command (the more specific form wins)", () => {
    expect(parseVoiceCommand("open TextEdit and type hello")).toEqual({
      status: "parsed",
      intent_type: "type_text",
      appName: "TextEdit",
      text: "hello",
    });
  });

  it("blocks unsupported commands", () => {
    expect(parseVoiceCommand("send it")).toEqual({
      status: "unsupported",
      reason: "Unsupported voice command",
    });
  });
});
