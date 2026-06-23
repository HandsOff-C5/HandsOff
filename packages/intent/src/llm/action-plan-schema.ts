import { z } from "zod";

import { INTENT_TYPES } from "@handsoff/contracts";
import { REFERENT_SOURCES } from "@handsoff/contracts";
import { RISK_LEVELS, TARGET_AGENTS } from "@handsoff/contracts";

const surfaceSnapshotSubsetSchema = z.object({
  id: z.string(),
  title: z.string(),
  app: z.string(),
  pid: z.number().nullable(),
  windowId: z.number().nullable(),
  availability: z.enum(["available", "minimized", "closed", "unknown"]),
  accessStatus: z.enum(["accessible", "restricted", "unknown"]),
});

const actionTargetSubsetSchema = z.object({
  surface: surfaceSnapshotSubsetSchema,
  elementId: z.string().nullable(),
  elementIndex: z.number().nullable(),
});

const actionStepBaseSubsetSchema = z.object({
  id: z.string(),
  label: z.string(),
});

const targetedActionStepSubsetSchema = actionStepBaseSubsetSchema.extend({
  kind: z.enum([
    "inspect_window_state",
    "click_element",
    "type_text",
    "set_value",
    "capture_screenshot",
  ]),
  target: actionTargetSubsetSchema,
  text: z.string().nullable(),
  value: z.string().nullable(),
});

const launchAppStepSubsetSchema = actionStepBaseSubsetSchema.extend({
  kind: z.literal("launch_app"),
  appName: z.string(),
  bundleId: z.string().nullable(),
});

const actionStepSubsetSchema = z.discriminatedUnion("kind", [
  launchAppStepSubsetSchema,
  targetedActionStepSubsetSchema,
]);

export const openAiActionPlanSchema = z.object({
  id: z.string(),
  summary: z.string(),
  risk_level: z.enum(RISK_LEVELS),
  requires_approval: z.boolean(),
  target_agent: z.enum(TARGET_AGENTS),
  action_plan: z.array(actionStepSubsetSchema),
});
export type OpenAiActionPlan = z.infer<typeof openAiActionPlanSchema>;

export const openAiResolvedIntentSchema = z.object({
  status: z.enum(["ready", "clarification_required", "blocked"]),
  id: z.string(),
  intent_type: z.enum(INTENT_TYPES).nullable(),
  referent: z
    .object({
      id: z.string(),
      source: z.enum(REFERENT_SOURCES),
      confidence: z.number(),
    })
    .nullable(),
  constraints: z.array(z.string()),
  risk_level: z.enum(RISK_LEVELS).nullable(),
  requires_approval: z.boolean(),
  target_agent: z.enum(TARGET_AGENTS),
  action_plan: openAiActionPlanSchema.nullable(),
  reason: z.string().nullable(),
});
export type OpenAiResolvedIntent = z.infer<typeof openAiResolvedIntentSchema>;
