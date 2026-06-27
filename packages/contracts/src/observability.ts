import { z } from "zod";

const forbiddenField = /credential|password|prompt|raw|screenshot|secret|token|transcript/i;

const finiteNumberSchema = z.number().finite();
const attributeValueSchema = z.union([z.string(), finiteNumberSchema, z.boolean(), z.null()]);

const attributesSchema = z
  .record(z.string().min(1), attributeValueSchema)
  .refine((attributes) => Object.keys(attributes).every((key) => !forbiddenField.test(key)), {
    message: "observability attributes must not include private/raw field names",
  });

const baseRecordSchema = z.object({
  timestamp: z.string().datetime(),
  component: z.string().min(1),
  event: z.string().min(1),
  release: z.string().min(1).optional(),
  platform: z.string().min(1).optional(),
  sessionId: z.string().min(1).optional(),
  correlationId: z.string().min(1).optional(),
  traceId: z.string().min(1).optional(),
  spanId: z.string().min(1).optional(),
  attributes: attributesSchema.default({}),
});

export const observabilityRecordSchema = z.discriminatedUnion("kind", [
  baseRecordSchema.extend({
    kind: z.literal("log"),
    level: z.enum(["debug", "info", "warn", "error"]),
  }),
  baseRecordSchema.extend({
    kind: z.literal("span"),
    parentSpanId: z.string().min(1).optional(),
    durationMs: finiteNumberSchema.nonnegative().optional(),
    status: z.enum(["ok", "error"]).default("ok"),
  }),
  baseRecordSchema.extend({
    kind: z.literal("metric"),
    name: z.string().min(1),
    value: finiteNumberSchema,
    unit: z.string().min(1).optional(),
  }),
  baseRecordSchema.extend({
    kind: z.literal("analytics"),
    stage: z.enum([
      "session_started",
      "context_selected",
      "transcript_accepted",
      "plan_approved",
      "plan_rejected",
      "action_completed",
      "action_failed",
      "interrupt_used",
    ]),
  }),
  baseRecordSchema.extend({
    kind: z.literal("error"),
    errorClass: z.string().min(1),
    handled: z.boolean(),
  }),
]);
export type ObservabilityRecord = z.infer<typeof observabilityRecordSchema>;

export function safeParseObservabilityRecord(
  input: unknown,
): z.SafeParseReturnType<unknown, ObservabilityRecord> {
  return observabilityRecordSchema.safeParse(input);
}

export class ObservabilityMemorySink {
  #records: ObservabilityRecord[] = [];

  emit(record: ObservabilityRecord): void {
    this.#records.push(record);
  }

  records(): ObservabilityRecord[] {
    return [...this.#records];
  }
}
