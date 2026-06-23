import { z } from "zod";

import { surfaceSnapshotSchema } from "./surface";

// Clarification prompt (#36). When the intent engine can't confidently bind the
// referent it asks instead of acting (AD5: clarify below threshold). This is the
// structured ask the dashboard renders — distinct from the free-text `reason` on
// a `clarification_required` ResolvedIntent, which stays for logging.

// Why the engine asked. `low_confidence`: one weak target. `ambiguous`: the top
// candidates are too close to choose between. `no_target`: nothing under the ray.
export const CLARIFICATION_REASONS = ["low_confidence", "ambiguous", "no_target"] as const;
export const clarificationReasonSchema = z.enum(CLARIFICATION_REASONS);
export type ClarificationReason = z.infer<typeof clarificationReasonSchema>;

// One disambiguation choice the user can pick. `confidence` is the CALIBRATED
// score (#100), not raw MediaPipe, so the displayed numbers are meaningful.
export const clarificationOptionSchema = z.object({
  targetId: z.string().min(1),
  label: z.string().min(1),
  surface: surfaceSnapshotSchema.optional(),
  confidence: z.number().min(0).max(1),
});
export type ClarificationOption = z.infer<typeof clarificationOptionSchema>;

// The ask: a reason, a human question, and the options to choose from. `options`
// is empty for `no_target` (nothing to pick — the UI shows a re-point prompt).
export const clarificationRequestSchema = z.object({
  reason: clarificationReasonSchema,
  question: z.string().min(1),
  options: z.array(clarificationOptionSchema),
});
export type ClarificationRequest = z.infer<typeof clarificationRequestSchema>;
