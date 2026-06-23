import type { IntentInput } from "@handsoff/contracts";

export interface ResolveIntentMessage {
  readonly role: "system" | "user";
  readonly content: string;
}

export function buildResolveIntentMessages(input: IntentInput): ResolveIntentMessage[] {
  return [
    {
      role: "system",
      content:
        "Resolve the user's transcript into a HandsOff action plan. You are the natural-language command parser; use only the supplied transcript and ordered candidate surface metadata. You may launch a named macOS app before typing into it. For named app launch targets, use surface id app:<lowercase app name> with pid/windowId null and unknown availability/access. For this/current app/window/document with no candidate surfaces, use surface id active-window, title Active window, app Current app, pid/windowId null, availability available, accessStatus accessible. If the target is ambiguous, blocked, or unsafe, return clarification_required or blocked. Never produce destructive actions.",
    },
    {
      role: "user",
      content: JSON.stringify({
        transcript: {
          text: input.speech.finalTranscript.text,
          confidence: input.speech.finalTranscript.confidence,
        },
        candidateSurfaces: input.surfaceCandidates.map((surface, index) => ({
          rank: index + 1,
          id: surface.id,
          title: surface.title,
          app: surface.app,
          pid: surface.pid ?? null,
          windowId: surface.windowId ?? null,
          availability: surface.availability,
          accessStatus: surface.accessStatus,
        })),
      }),
    },
  ];
}
