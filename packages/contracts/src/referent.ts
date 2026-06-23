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

// ---------------------------------------------------------------------------
// Pointing referent pipeline (gesture epic #7). Schema-only types the gesture
// lane passes across the boundary: they mirror the MediaPipe Hand Landmarker
// output on the input side and the calibration / state-machine outputs on the
// downstream side. The intent engine consumes `PointingCandidate` and fuses it
// with the transcript; `SelectedReferent` above is the persisted result.
// ---------------------------------------------------------------------------

// One hand landmark — MediaPipe NormalizedLandmark: x/y normalized to [0,1],
// z is relative depth (wrist origin), visibility in [0,1].
export const Landmark = z.object({
  x: z.number(),
  y: z.number(),
  z: z.number(),
  visibility: z.number().min(0).max(1),
});
export type Landmark = z.infer<typeof Landmark>;

export const Handedness = z.enum(["Left", "Right"]);
export type Handedness = z.infer<typeof Handedness>;

// One detected hand: exactly 21 landmarks plus handedness and its confidence.
export const Hand = z.object({
  landmarks: z.array(Landmark).length(21),
  handedness: Handedness,
  score: z.number().min(0).max(1),
});
export type Hand = z.infer<typeof Hand>;

// One parsed perception frame — the output of the single `parseLandmarkFrame`
// the runtime and the #29 fixtures both use. Empty `hands` = no hand detected.
export const LandmarkFrame = z.object({
  timestampMs: z.number(),
  hands: z.array(Hand),
});
export type LandmarkFrame = z.infer<typeof LandmarkFrame>;

export const CalibrationQuality = z.enum(["good", "fair", "poor"]);
export type CalibrationQuality = z.infer<typeof CalibrationQuality>;

// A pointing referent candidate — output of calibration (#26). Not yet committed.
export const PointingCandidate = z.object({
  targetId: z.string(),
  confidence: z.number().min(0).max(1),
  calibrationQuality: CalibrationQuality,
});
export type PointingCandidate = z.infer<typeof PointingCandidate>;

// A candidate promoted to a locked referent by the state machine (#27).
export const LockedReferent = z.object({
  targetId: z.string(),
  confidence: z.number().min(0).max(1),
  lockedAtMs: z.number(),
});
export type LockedReferent = z.infer<typeof LockedReferent>;

// Gesture state-machine states (#27).
export const GestureState = z.enum(["idle", "candidate", "locked", "interrupt"]);
export type GestureState = z.infer<typeof GestureState>;

// Explicit interrupt emitted by cancel / pause / stop gestures (#27; the
// always-available interrupt path from FINAL_PLANNING AD5).
export const InterruptIntent = z.object({
  kind: z.enum(["pause", "stop", "cancel"]),
});
export type InterruptIntent = z.infer<typeof InterruptIntent>;
