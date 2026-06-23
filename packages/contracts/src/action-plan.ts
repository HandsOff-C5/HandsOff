import { z } from "zod";

import { surfaceSnapshotSchema } from "./surface";

export const RISK_LEVELS = ["read_only", "reversible", "mutating", "destructive"] as const;
export const riskLevelSchema = z.enum(RISK_LEVELS);
export type RiskLevel = z.infer<typeof riskLevelSchema>;

export const TARGET_AGENTS = ["cua-driver", "none"] as const;
export const targetAgentSchema = z.enum(TARGET_AGENTS);
export type TargetAgent = z.infer<typeof targetAgentSchema>;

export const actionTargetSchema = z.object({
  surface: surfaceSnapshotSchema,
  elementId: z.string().min(1).optional(),
  elementIndex: z.number().int().nonnegative().optional(),
});
export type ActionTarget = z.infer<typeof actionTargetSchema>;

const actionStepBaseSchema = z.object({
  id: z.string().min(1),
  label: z.string().min(1),
  target: actionTargetSchema,
});

export const actionStepSchema = z.discriminatedUnion("kind", [
  actionStepBaseSchema.extend({
    kind: z.literal("inspect_window_state"),
  }),
  actionStepBaseSchema.extend({
    kind: z.literal("click_element"),
  }),
  actionStepBaseSchema.extend({
    kind: z.literal("type_text"),
    text: z.string().min(1),
  }),
  actionStepBaseSchema.extend({
    kind: z.literal("set_value"),
    value: z.string(),
  }),
  actionStepBaseSchema.extend({
    kind: z.literal("capture_screenshot"),
  }),
]);
export type ActionStep = z.infer<typeof actionStepSchema>;

const actionPlanBaseSchema = z.object({
  id: z.string().min(1),
  summary: z.string().min(1),
  risk_level: riskLevelSchema,
  requires_approval: z.boolean(),
  target_agent: targetAgentSchema,
  action_plan: z.array(actionStepSchema),
});
export const actionPlanSchema = actionPlanBaseSchema.refine(
  (plan) => plan.risk_level !== "destructive",
  {
    message: "destructive actions are unsupported in this slice",
  },
);
export type ActionPlan = z.infer<typeof actionPlanSchema>;

export const approvalDecisionSchema = z.object({
  actionId: z.string().min(1),
  decision: z.enum(["approved", "rejected"]),
  decidedAt: z.string().datetime(),
});
export type ApprovalDecision = z.infer<typeof approvalDecisionSchema>;

export const executionStatusSchema = z.enum([
  "queued",
  "running",
  "succeeded",
  "failed",
  "blocked",
  "rejected",
]);
export type ExecutionStatus = z.infer<typeof executionStatusSchema>;

export function safeParseActionPlan(input: unknown): z.SafeParseReturnType<unknown, ActionPlan> {
  return actionPlanSchema.safeParse(input);
}
