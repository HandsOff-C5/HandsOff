import { z } from "zod";

import { actionPlanSchema, riskLevelSchema, targetAgentSchema } from "./action-plan";
import { selectedReferentSchema } from "./referent";
import { surfaceSnapshotSchema } from "./surface";
import { finalTranscriptSchema } from "./transcript";

export const INTENT_TYPES = [
  "inspect",
  "click",
  "type_text",
  "set_value",
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

export const intentInputSchema = z.object({
  sessionId: z.string().min(1),
  speech: z.object({
    finalTranscript: finalTranscriptSchema,
  }),
  pointingEvidence: z.array(pointingEvidenceSchema).min(1),
  surfaceCandidates: z.array(surfaceSnapshotSchema),
});
export type IntentInput = z.infer<typeof intentInputSchema>;

export const resolvedIntentSchema = z.discriminatedUnion("status", [
  z.object({
    status: z.literal("ready"),
    id: z.string().min(1),
    input: intentInputSchema,
    intent_type: intentTypeSchema,
    referent: selectedReferentSchema,
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
    createdAt: z.string().datetime(),
  }),
]);
export type ResolvedIntent = z.infer<typeof resolvedIntentSchema>;

export function safeParseResolvedIntent(
  input: unknown,
): z.SafeParseReturnType<unknown, ResolvedIntent> {
  return resolvedIntentSchema.safeParse(input);
}
