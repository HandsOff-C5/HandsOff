import { z } from "zod";

import { surfaceSnapshotSchema } from "./surface";

export const RISK_LEVELS = ["read_only", "reversible", "mutating", "destructive_external"] as const;
export const riskLevelSchema = z.enum(RISK_LEVELS);
export type RiskLevel = z.infer<typeof riskLevelSchema>;

export function riskLevelRequiresApproval(riskLevel: RiskLevel): boolean {
  return riskLevel === "mutating" || riskLevel === "destructive_external";
}

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
});

export const actionStepSchema = z.discriminatedUnion("kind", [
  actionStepBaseSchema.extend({
    kind: z.literal("inspect_window_state"),
    target: actionTargetSchema,
  }),
  actionStepBaseSchema.extend({
    kind: z.literal("click_element"),
    target: actionTargetSchema,
  }),
  actionStepBaseSchema.extend({
    kind: z.literal("type_text"),
    target: actionTargetSchema,
    text: z.string().min(1),
  }),
  actionStepBaseSchema.extend({
    kind: z.literal("set_value"),
    target: actionTargetSchema,
    value: z.string(),
  }),
  actionStepBaseSchema.extend({
    kind: z.literal("capture_screenshot"),
    target: actionTargetSchema,
  }),
  actionStepBaseSchema.extend({
    kind: z.literal("launch_app"),
    appName: z.string().min(1),
    bundleId: z.string().min(1).optional(),
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
  (plan) => plan.requires_approval === riskLevelRequiresApproval(plan.risk_level),
  {
    message: "requires_approval must match risk_level",
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
