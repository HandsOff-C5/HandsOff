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
        "Resolve the user's transcript into a HandsOff action plan. Use only the supplied transcript and ordered candidate surface metadata. If the target is ambiguous, blocked, or unsafe, return clarification_required or blocked. Never produce destructive actions.",
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
