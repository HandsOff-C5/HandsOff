import { describe, expect, it } from "vitest";

import { resolveWithOpenAi, type OpenAiIntentClient } from "../llm/openai-resolver";
import goldens from "./head-intent-llm-goldens.json";
import type { IntentInput, ResolvedIntent, SurfaceSnapshot } from "@handsoff/contracts";
import type { OpenAiResolvedIntent } from "../llm/action-plan-schema";

type Golden = {
  readonly name: string;
  readonly transcript: string;
  readonly candidateSurfaces: readonly SurfaceSnapshot[];
  readonly completion: OpenAiResolvedIntent;
  readonly expected: {
    readonly status: ResolvedIntent["status"];
    readonly intent_type?: string;
    readonly referentId?: string;
    readonly target_agent: string;
    readonly requires_approval: boolean;
    readonly actionKinds: readonly string[];
  };
};

function input(golden: Golden): IntentInput {
  return {
    sessionId: "session-1",
    speech: {
      finalTranscript: {
        kind: "final",
        text: golden.transcript,
        confidence: 0.95,
        latencyMs: 100,
        receivedAt: 1,
      },
    },
    pointingEvidence: [
      {
        source: "head",
        confidence: 0.9,
        strategy: "head-neighborhood",
        surface: golden.candidateSurfaces[0],
      },
    ],
    surfaceCandidates: [...golden.candidateSurfaces],
  };
}

function project(intent: ResolvedIntent) {
  return {
    status: intent.status,
    intent_type: "intent_type" in intent ? intent.intent_type : undefined,
    referentId: "referent" in intent ? intent.referent.id : undefined,
    target_agent: intent.target_agent,
    requires_approval: intent.requires_approval,
    actionKinds:
      "action_plan" in intent ? intent.action_plan.action_plan.map((step) => step.kind) : [],
  };
}

describe("head intent LLM golden evals", () => {
  it.each(goldens as readonly Golden[])("$name", async (golden) => {
    const client: OpenAiIntentClient = {
      chat: {
        completions: {
          async parse() {
            return {
              choices: [
                {
                  finish_reason: "stop",
                  message: { parsed: golden.completion },
                },
              ],
            };
          },
        },
      },
    };

    const resolved = await resolveWithOpenAi(input(golden), {
      client,
      createdAt: "2026-06-22T12:00:00.000Z",
    });

    expect(project(resolved)).toEqual(golden.expected);
  });
});
