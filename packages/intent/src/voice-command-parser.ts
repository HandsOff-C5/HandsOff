import type { IntentType } from "@handsoff/contracts";

export type ParsedVoiceCommand =
  | { status: "parsed"; intent_type: IntentType; text?: string; value?: string }
  | { status: "unsupported"; reason: string };

export function parseVoiceCommand(transcript: string): ParsedVoiceCommand {
  const text = transcript.trim().toLowerCase();
  if (!text) {
    return { status: "unsupported", reason: "Empty transcript" };
  }
  if (text === "pause" || text === "pause it") {
    return { status: "parsed", intent_type: "pause" };
  }
  if (text === "stop" || text === "stop it") {
    return { status: "parsed", intent_type: "stop" };
  }
  if (text.startsWith("inspect ") || text === "inspect this window" || text === "look at this") {
    return { status: "parsed", intent_type: "inspect" };
  }
  if (text.startsWith("click") || text === "press that") {
    return { status: "parsed", intent_type: "click" };
  }
  if (text.startsWith("type ")) {
    const dictated = transcript
      .trim()
      .replace(/^type\s+/i, "")
      .replace(/\s+(into|in)\s+(that|this|there)$/i, "");
    return dictated
      ? { status: "parsed", intent_type: "type_text", text: dictated }
      : unsupported();
  }
  const setMatch = transcript.trim().match(/^set\s+.+\s+to\s+(.+)$/i);
  if (setMatch?.[1]) {
    return { status: "parsed", intent_type: "set_value", value: setMatch[1] };
  }
  return unsupported();
}

function unsupported(): ParsedVoiceCommand {
  return { status: "unsupported", reason: "Unsupported voice command" };
}
