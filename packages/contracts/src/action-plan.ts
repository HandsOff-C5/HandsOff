import { z } from "zod";

import { driverToolSchema } from "./driver-tools";
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
  // The generic full-surface step (U3b): a direct call to any cua-driver tool by
  // name with its raw flat args (the driver's own snake_case shape, e.g.
  // { pid, window_id, element_index, direction }). This is how the autonomous
  // loop reaches all 36 driver tools through the U1 passthrough instead of the
  // closed 6-kind vocabulary above. `tool` is the `DriverTool` enum (sourced from
  // the dependency-free `./driver-tools` module, so this carries no `tool-risk`
  // import cycle): an off-surface tool name fails to parse at the schema boundary
  // rather than reaching dispatch. The loop's `safeParseDriverTool` /
  // `riskForToolName` boundary check stays as defense-in-depth (and gates an
  // unknown tool as mutating), now also a compile-time guarantee. The legacy
  // kinds remain for the rule resolver. `args` stays a free record — the driver
  // owns each tool's per-arg schema; this is a self-describing passthrough.
  actionStepBaseSchema.extend({
    kind: z.literal("tool_call"),
    tool: driverToolSchema,
    args: z.record(z.unknown()).default({}),
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
