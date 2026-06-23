import type { SupervisionAuditEvent } from "@handsoff/contracts";

import type { LoopEntry } from "./computer-use-loop";

// STUB — red phase. The failing test demands the real mapping.
export function cuaTranscriptToAuditEvents(args: {
  sessionId: string;
  actionId: string;
  recordedAt: string;
  transcript: readonly LoopEntry[];
}): SupervisionAuditEvent[] {
  void args;
  return [];
}
