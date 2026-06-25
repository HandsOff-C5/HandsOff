import { z } from "zod";

import { approvalDecisionSchema, executionStatusSchema } from "./action-plan";
import { cuaActionRequestSchema, cuaActionResultSchema, cuaWindowStateSchema } from "./cua";
import { resolvedIntentSchema } from "./intent";
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

const auditEventBaseSchema = z.object({
  sessionId: z.string().min(1),
  actionId: z.string().min(1),
  recordedAt: z.string().datetime(),
});

export const supervisionAuditEventSchema = z
  .discriminatedUnion("kind", [
    auditEventBaseSchema.extend({
      kind: z.literal("intent_created"),
      intent: resolvedIntentSchema,
    }),
    auditEventBaseSchema.extend({
      kind: z.literal("approval_decided"),
      approval: approvalDecisionSchema,
    }),
    auditEventBaseSchema.extend({
      kind: z.literal("cua_state_captured"),
      phase: z.enum(["pre", "post"]),
      stepId: z.string().min(1),
      state: cuaWindowStateSchema,
    }),
    auditEventBaseSchema.extend({
      kind: z.literal("cua_call"),
      stepId: z.string().min(1),
      request: cuaActionRequestSchema,
      result: cuaActionResultSchema,
    }),
    auditEventBaseSchema.extend({
      kind: z.literal("execution_finished"),
      status: executionStatusSchema,
      result: cuaActionResultSchema.optional(),
    }),
  ])
  .refine(
    (event) => event.kind !== "approval_decided" || event.approval.actionId === event.actionId,
    {
      message: "approval actionId must match audit actionId",
    },
  );
export type SupervisionAuditEvent = z.infer<typeof supervisionAuditEventSchema>;

export function safeParseSupervisionAuditEvent(
  input: unknown,
): z.SafeParseReturnType<unknown, SupervisionAuditEvent> {
  return supervisionAuditEventSchema.safeParse(input);
}
