import { z } from "zod";

import { actionPlanSchema, riskLevelSchema, targetAgentSchema } from "./action-plan";
import { clarificationRequestSchema } from "./clarification";
import { cuaActionResultSchema, cuaWindowStateSchema } from "./cua";
import { selectedReferentSchema } from "./referent";
import { surfaceSnapshotSchema } from "./surface";
import { finalTranscriptSchema } from "./transcript";

export const INTENT_TYPES = [
  "inspect",
  "click",
  "type_text",
  "set_value",
  "launch",
  "pause",
  "stop",
] as const;
export const intentTypeSchema = z.enum(INTENT_TYPES);
export type IntentType = z.infer<typeof intentTypeSchema>;

export const pointingEvidenceSchema = z.object({
  source: z.enum(["gesture", "gaze", "head", "face", "cursor", "active_window", "fusion"]),
  confidence: z.number().min(0).max(1),
  strategy: z.string().min(1),
  surface: surfaceSnapshotSchema.optional(),
  cursor: z
    .object({
      x: z.number(),
      y: z.number(),
    })
    .optional(),
});
export type PointingEvidence = z.infer<typeof pointingEvidenceSchema>;

export const goalLoopObservationSchema = z.object({
  tick: z.number().int().nonnegative(),
  capturedAt: z.string().datetime(),
  windows: z.array(surfaceSnapshotSchema),
  state: cuaWindowStateSchema.optional(),
  previousAction: z
    .object({
      actionId: z.string().min(1),
      result: cuaActionResultSchema,
    })
    .optional(),
});
export type GoalLoopObservation = z.infer<typeof goalLoopObservationSchema>;

export const goalSessionInputSchema = z.object({
  goal: z.string().min(1),
  tick: z.number().int().nonnegative(),
  observations: z.array(goalLoopObservationSchema),
});
export type GoalSessionInput = z.infer<typeof goalSessionInputSchema>;

export const intentInputSchema = z.object({
  sessionId: z.string().min(1),
  speech: z.object({
    finalTranscript: finalTranscriptSchema,
  }),
  pointingEvidence: z.array(pointingEvidenceSchema).min(1),
  surfaceCandidates: z.array(surfaceSnapshotSchema),
  goalSession: goalSessionInputSchema.optional(),
});
export type IntentInput = z.infer<typeof intentInputSchema>;

export const resolvedIntentSchema = z.discriminatedUnion("status", [
  z.object({
    status: z.literal("ready"),
    id: z.string().min(1),
    input: intentInputSchema,
    intent_type: intentTypeSchema,
    // Null for referent-less actions such as launching a named app — there is no
    // pointed-at surface to ground. Targeted actions still carry their surface on
    // each action step, so execution never depends on this field.
    referent: selectedReferentSchema.nullable(),
    constraints: z.array(z.string()),
    risk_level: riskLevelSchema,
    requires_approval: z.boolean(),
    target_agent: targetAgentSchema,
    action_plan: actionPlanSchema,
    createdAt: z.string().datetime(),
  }),
  z.object({
    status: z.enum(["clarification_required", "blocked"]),
    id: z.string().min(1),
    input: intentInputSchema,
    intent_type: intentTypeSchema.optional(),
    constraints: z.array(z.string()).default([]),
    risk_level: riskLevelSchema.optional(),
    requires_approval: z.boolean(),
    target_agent: targetAgentSchema,
    reason: z.string().min(1),
    // Structured prompt for the dashboard when status is clarification_required
    // (#36). Absent on `blocked` and on log-only clarifications.
    clarification: clarificationRequestSchema.optional(),
    createdAt: z.string().datetime(),
  }),
  z.object({
    status: z.literal("satisfied"),
    id: z.string().min(1),
    input: intentInputSchema,
    requires_approval: z.literal(false),
    target_agent: z.literal("none"),
    summary: z.string().min(1),
    createdAt: z.string().datetime(),
  }),
]);
export type ResolvedIntent = z.infer<typeof resolvedIntentSchema>;

export function safeParseResolvedIntent(
  input: unknown,
): z.SafeParseReturnType<unknown, ResolvedIntent> {
  return resolvedIntentSchema.safeParse(input);
}
