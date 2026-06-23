import { z } from "zod";

import { pointingEvidenceSchema } from "./intent";
import { surfaceSnapshotSchema } from "./surface";

const epochMsSchema = z.number().finite().nonnegative();
const coordinateSchema = z.number().finite();

export const headPointSchema = z.object({
  x: coordinateSchema,
  y: coordinateSchema,
});
export type HeadPoint = z.infer<typeof headPointSchema>;

const headPointingTimedEventSchema = z.object({
  ts: epochMsSchema,
});

export const headPointingEventSchema = z.discriminatedUnion("kind", [
  headPointingTimedEventSchema.extend({
    kind: z.literal("start"),
  }),
  headPointingTimedEventSchema.extend({
    kind: z.literal("point"),
    x: coordinateSchema,
    y: coordinateSchema,
    yaw: z.number().finite().nullable(),
    pitch: z.number().finite().nullable(),
    confidence: z.number().min(0).max(1),
  }),
  headPointingTimedEventSchema.extend({
    kind: z.literal("stop"),
  }),
  headPointingTimedEventSchema.extend({
    kind: z.literal("error"),
    message: z.string().min(1),
  }),
]);
export type HeadPointingEvent = z.infer<typeof headPointingEventSchema>;

export const attentionRegionCandidateSchema = z.object({
  surface: surfaceSnapshotSchema,
  score: z.number().min(0).max(1),
  distance: z.number().nonnegative(),
});
export type AttentionRegionCandidate = z.infer<typeof attentionRegionCandidateSchema>;

export const headPointingCandidatesEventSchema = z.object({
  kind: z.literal("candidates"),
  point: headPointSchema,
  candidates: z.array(attentionRegionCandidateSchema),
  ts: epochMsSchema,
});
export type HeadPointingCandidatesEvent = z.infer<typeof headPointingCandidatesEventSchema>;

export const headPointingAppEventSchema = z.union([
  headPointingEventSchema,
  headPointingCandidatesEventSchema,
]);
export type HeadPointingAppEvent = z.infer<typeof headPointingAppEventSchema>;

export function safeParseHeadPointingEvent(
  input: unknown,
): z.SafeParseReturnType<unknown, HeadPointingEvent> {
  return headPointingEventSchema.safeParse(input);
}

export function safeParseAttentionRegionCandidate(
  input: unknown,
): z.SafeParseReturnType<unknown, AttentionRegionCandidate> {
  return attentionRegionCandidateSchema.safeParse(input);
}

export function safeParseHeadPointingAppEvent(
  input: unknown,
): z.SafeParseReturnType<unknown, HeadPointingAppEvent> {
  return headPointingAppEventSchema.safeParse(input);
}

export function safeParseHeadPointingEvidence(
  input: unknown,
): z.SafeParseReturnType<unknown, z.infer<typeof pointingEvidenceSchema>> {
  return pointingEvidenceSchema.safeParse(input);
}
