import { z } from "zod";

// The deictic referent — *what* the user pointed at. Hand gesture plus face/eye
// tracking supplies the ~20% of intent that grounds "that", "this window", "the
// Codex run"; the perception layer emits a referent candidate with confidence,
// and the intent engine fuses it with the transcript before acting. Persisting
// the selected referent is what lets the audit trail replay a selection (#23).

// Which perception modality produced the referent. `fusion` covers a candidate
// resolved from more than one cue (e.g. a gesture narrowed by gaze). Kept as a
// string union so the gesture/intent lanes can grow the vocabulary (AD4).
export const REFERENT_SOURCES = ["gesture", "gaze", "head", "fusion"] as const;

export const referentSourceSchema = z.enum(REFERENT_SOURCES);
export type ReferentSource = z.infer<typeof referentSourceSchema>;

// Perception confidence in [0,1]. Below the intent engine's threshold the loop
// clarifies instead of acting (AD5); the raw score is still audited.
export const confidenceSchema = z.number().min(0).max(1);

// The selected referent as captured for the audit trail: a stable id, the
// modality that produced it, and the confidence behind it.
export const selectedReferentSchema = z.object({
  id: z.string().min(1),
  source: referentSourceSchema,
  confidence: confidenceSchema,
});
export type SelectedReferent = z.infer<typeof selectedReferentSchema>;
