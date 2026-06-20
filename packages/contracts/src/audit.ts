import { z } from "zod";

import { selectedReferentSchema } from "./referent";
import { surfaceSnapshotSchema } from "./surface";

// One audit-trail entry for the "select context" step of the core loop: the
// user pointed (referent) at a surface (snapshot), which a session/action then
// used. Persisting it makes the selection replayable — which surface did the
// user pick, how confident was perception, and which action consumed it
// (#23, epic #6).

export const surfaceSelectionRecordSchema = z.object({
  // The selected referent: id, source, confidence.
  referent: selectedReferentSchema,
  // The surface metadata as it was at selection time.
  surface: surfaceSnapshotSchema,
  // The supervision session the selection happened in. Always present — a
  // selection only has meaning inside a session.
  sessionId: z.string().min(1),
  // The action that consumed the selection. Optional because selection precedes
  // planning in the loop (select -> speak -> plan -> approve -> act); it is set
  // once an action claims the referent.
  actionId: z.string().min(1).optional(),
  // When the user made the selection, ISO 8601. Captured by the caller at
  // selection time, not when the record is persisted.
  selectedAt: z.string().datetime(),
});
export type SurfaceSelectionRecord = z.infer<typeof surfaceSelectionRecordSchema>;

// Validate an untrusted selection record at a boundary (IPC, persistence).
export function safeParseSurfaceSelectionRecord(
  input: unknown,
): z.SafeParseReturnType<unknown, SurfaceSelectionRecord> {
  return surfaceSelectionRecordSchema.safeParse(input);
}
