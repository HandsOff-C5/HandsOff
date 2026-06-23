import OpenAI from "openai";
import { zodResponseFormat } from "openai/helpers/zod";

import {
  actionPlanSchema,
  resolvedIntentSchema,
  type ActionPlan,
  type ActionStep,
  type IntentInput,
  type ResolvedIntent,
  type SurfaceSnapshot,
} from "@handsoff/contracts";

import { blockedIntent } from "../fuse-intent";
import { requiresApproval } from "../risk";
import {
  openAiResolvedIntentSchema,
  type OpenAiActionPlan,
  type OpenAiResolvedIntent,
} from "./action-plan-schema";
import { buildResolveIntentMessages } from "./prompt";

export interface OpenAiParsedChoice {
  readonly finish_reason: string | null;
  readonly message: {
    readonly parsed?: OpenAiResolvedIntent | null;
    readonly refusal?: string | null;
  };
}

export interface OpenAiIntentClient {
  readonly chat: {
    readonly completions: {
      parse(input: unknown): Promise<{ readonly choices: readonly OpenAiParsedChoice[] }>;
    };
  };
}

export interface OpenAiIntentResolverOptions {
  readonly client?: OpenAiIntentClient;
  readonly model?: string;
  readonly intentId?: string;
  readonly createdAt?: string;
}

const DEFAULT_MODEL = "gpt-4o-mini";

interface NormalizedParsedIntent {
  readonly status: OpenAiResolvedIntent["status"];
  readonly action_plan?: unknown;
  readonly [key: string]: unknown;
}

export async function resolveWithOpenAi(
  input: IntentInput,
  options: OpenAiIntentResolverOptions = {},
): Promise<ResolvedIntent> {
  const createdAt = options.createdAt ?? new Date().toISOString();
  const id = options.intentId ?? "intent-llm";

  try {
    const client = options.client ?? new OpenAI();
    const completion = await client.chat.completions.parse({
      model: options.model ?? DEFAULT_MODEL,
      messages: buildResolveIntentMessages(input),
      response_format: zodResponseFormat(openAiResolvedIntentSchema, "resolved_intent"),
    });
    const choice = completion.choices[0];
    if (!choice) {
      return blockedIntent(
        "blocked",
        input,
        id,
        createdAt,
        "The intent resolver returned no choice",
      );
    }
    if (choice.finish_reason === "length") {
      return blockedIntent(
        "clarification_required",
        input,
        id,
        createdAt,
        "The intent resolver response was truncated",
      );
    }
    if (choice.message.refusal) {
      return blockedIntent("clarification_required", input, id, createdAt, choice.message.refusal);
    }
    if (!choice.message.parsed) {
      return blockedIntent(
        "blocked",
        input,
        id,
        createdAt,
        "The intent resolver returned no parsed result",
      );
    }

    return validateParsedIntent(choice.message.parsed, input, createdAt);
  } catch (caught) {
    return blockedIntent(
      "blocked",
      input,
      id,
      createdAt,
      `Intent resolver failed: ${caught instanceof Error ? caught.message : String(caught)}`,
    );
  }
}

function validateParsedIntent(
  parsed: OpenAiResolvedIntent,
  input: IntentInput,
  createdAt: string,
): ResolvedIntent {
  const normalized = normalizeParsedIntent(parsed, input, createdAt);
  if (
    normalized.status === "ready" &&
    !actionPlanSchema.safeParse(normalized.action_plan).success
  ) {
    return blockedIntent(
      "blocked",
      input,
      parsed.id || "intent-llm",
      createdAt,
      "The intent resolver returned an invalid action plan",
    );
  }

  const validated = resolvedIntentSchema.safeParse(normalized);
  if (!validated.success) {
    return blockedIntent(
      "blocked",
      input,
      parsed.id || "intent-llm",
      createdAt,
      `The intent resolver returned an invalid intent: ${validated.error.message}`,
    );
  }
  return validated.data;
}

function normalizeParsedIntent(
  parsed: OpenAiResolvedIntent,
  input: IntentInput,
  createdAt: string,
): NormalizedParsedIntent {
  if (parsed.status !== "ready") {
    return {
      status: parsed.status,
      id: parsed.id,
      input,
      ...(parsed.intent_type !== null && { intent_type: parsed.intent_type }),
      constraints: parsed.constraints,
      ...(parsed.risk_level !== null && { risk_level: parsed.risk_level }),
      requires_approval: false,
      target_agent: "none",
      reason: parsed.reason ?? "The intent resolver could not produce a ready plan",
      createdAt,
    };
  }

  const requires_approval = parsed.risk_level ? requiresApproval(parsed.risk_level) : false;
  return {
    status: "ready",
    id: parsed.id,
    input,
    intent_type: parsed.intent_type,
    referent: parsed.referent,
    constraints: parsed.constraints,
    risk_level: parsed.risk_level,
    requires_approval,
    target_agent: parsed.target_agent,
    action_plan: parsed.action_plan ? normalizeActionPlan(parsed.action_plan) : null,
    createdAt,
  };
}

function normalizeActionPlan(plan: OpenAiResolvedIntent["action_plan"]): ActionPlan | null {
  if (!plan) return null;
  return {
    id: plan.id,
    summary: plan.summary,
    risk_level: plan.risk_level,
    requires_approval: requiresApproval(plan.risk_level),
    target_agent: plan.target_agent,
    action_plan: plan.action_plan.map(normalizeStep),
  };
}

type OpenAiActionStep = OpenAiActionPlan["action_plan"][number];
type OpenAiTargetedActionStep = Extract<OpenAiActionStep, { target: unknown }>;
type OpenAiSurface = OpenAiTargetedActionStep["target"]["surface"];

function normalizeStep(step: OpenAiActionStep): ActionStep {
  if (step.kind === "launch_app") {
    return {
      id: step.id,
      kind: "launch_app",
      label: step.label,
      appName: step.appName,
      ...(step.bundleId !== null && { bundleId: step.bundleId }),
    };
  }

  const target = {
    surface: normalizeSurface(step.target.surface),
    ...(step.target.elementId !== null && { elementId: step.target.elementId }),
    ...(step.target.elementIndex !== null && { elementIndex: step.target.elementIndex }),
  };

  switch (step.kind) {
    case "type_text":
      return { id: step.id, kind: step.kind, label: step.label, target, text: step.text ?? "" };
    case "set_value":
      return { id: step.id, kind: step.kind, label: step.label, target, value: step.value ?? "" };
    default:
      return { id: step.id, kind: step.kind, label: step.label, target };
  }
}

function normalizeSurface(surface: OpenAiSurface): SurfaceSnapshot {
  return {
    id: surface.id,
    title: surface.title,
    app: surface.app,
    ...(surface.pid !== null && { pid: surface.pid }),
    ...(surface.windowId !== null && { windowId: surface.windowId }),
    availability: surface.availability,
    accessStatus: surface.accessStatus,
  };
}
