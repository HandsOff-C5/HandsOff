import type { IntentType } from "@handsoff/contracts";

export type ParsedVoiceCommand =
  | {
      status: "parsed";
      intent_type: IntentType;
      text?: string;
      value?: string;
      appName?: string;
    }
  | { status: "unsupported"; reason: string };

export function parseVoiceCommand(transcript: string): ParsedVoiceCommand {
  const command = cleanTranscript(transcript);
  const text = command.toLowerCase();
  if (!text) {
    return { status: "unsupported", reason: "Empty transcript" };
  }
  if (text === "pause" || text === "pause it") {
    return { status: "parsed", intent_type: "pause" };
  }
  if (text === "stop" || text === "stop it") {
    return { status: "parsed", intent_type: "stop" };
  }
  const openAndType = command.match(/^(?:open|launch)\s+(.+?)\s+and\s+type\s+(.+)$/i);
  if (openAndType?.[1] && openAndType[2]) {
    return {
      status: "parsed",
      intent_type: "type_text",
      appName: openAndType[1].trim(),
      text: openAndType[2].trim(),
    };
  }
  // Bare "open/launch <app>" (the golden flow's "open Cursor") — deterministic, so the
  // launch fires without the LLM. Matched after the "and type" form so that wins.
  const open = command.match(/^(?:open|launch)\s+(.+)$/i);
  if (open?.[1]) {
    return { status: "parsed", intent_type: "launch", appName: open[1].trim() };
  }
  if (text.startsWith("inspect ") || text === "inspect this window" || text === "look at this") {
    return { status: "parsed", intent_type: "inspect" };
  }
  if (text.startsWith("click") || text === "press that") {
    return { status: "parsed", intent_type: "click" };
  }
  if (text.startsWith("type ")) {
    const dictated = command
      .replace(/^type\s+/i, "")
      .replace(/\s+(into|in)\s+(that|this|there)$/i, "");
    return dictated
      ? { status: "parsed", intent_type: "type_text", text: dictated }
      : unsupported();
  }
  const setMatch = command.match(/^set\s+.+\s+to\s+(.+)$/i);
  if (setMatch?.[1]) {
    return { status: "parsed", intent_type: "set_value", value: setMatch[1] };
  }
  return unsupported();
}

function cleanTranscript(transcript: string): string {
  return transcript
    .split(/\r?\n/)
    .filter((line) => !/^\s*\d+(?:\.\d+)?%\s+\u00b7\s+\d+(?:\.\d+)?\s*ms\s*$/i.test(line))
    .join(" ")
    .replace(/\s+\d+(?:\.\d+)?%\s+\u00b7\s+\d+(?:\.\d+)?\s*ms\s*$/i, "")
    .replace(/\s+/g, " ")
    .trim();
}

function unsupported(): ParsedVoiceCommand {
  return { status: "unsupported", reason: "Unsupported voice command" };
}
