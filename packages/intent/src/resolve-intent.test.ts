import { describe, expect, it } from "vitest";

import type { IntentInput, SurfaceSnapshot } from "@handsoff/contracts";

import { resolveIntent } from "./resolve-intent";
import type { OpenAiIntentClient } from "./llm/openai-resolver";

const surface: SurfaceSnapshot = {
  id: "surface-1",
  title: "Notes",
  app: "Notes",
  pid: 42,
  windowId: 7,
  availability: "available",
  accessStatus: "accessible",
};

function input(text = "click there"): IntentInput {
  return {
    sessionId: "session-1",
    speech: {
      finalTranscript: {
        kind: "final",
        text,
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
        surface,
      },
    ],
    surfaceCandidates: [surface],
  };
}

describe("resolveIntent", () => {
  it("keeps the rule resolver available unchanged", async () => {
    await expect(
      resolveIntent(input(), {
        resolver: "rule",
        intentId: "intent-rule",
        planId: "plan-rule",
        createdAt: "2026-06-22T12:00:00.000Z",
      }),
    ).resolves.toMatchObject({
      status: "ready",
      id: "intent-rule",
      action_plan: { id: "plan-rule", action_plan: [{ kind: "click_element" }] },
    });
  });

  it("defaults to the rule resolver so LLM calls stay explicit", async () => {
    await expect(
      resolveIntent(input(), {
        intentId: "intent-rule",
        planId: "plan-rule",
        createdAt: "2026-06-22T12:00:00.000Z",
      }),
    ).resolves.toMatchObject({
      status: "ready",
      id: "intent-rule",
      action_plan: { id: "plan-rule", action_plan: [{ kind: "click_element" }] },
    });
  });

  it("routes to the llm resolver seam when requested", async () => {
    const client: OpenAiIntentClient = {
      chat: {
        completions: {
          async parse() {
            return {
              choices: [
                {
                  finish_reason: "stop",
                  message: {
                    parsed: {
                      status: "blocked",
                      id: "intent-llm",
                      intent_type: null,
                      referent: null,
                      constraints: [],
                      risk_level: null,
                      requires_approval: false,
                      target_agent: "none",
                      action_plan: null,
                      reason: "Need a clearer target",
                    },
                  },
                },
              ],
            };
          },
        },
      },
    };

    await expect(resolveIntent(input(), { resolver: "llm", client })).resolves.toMatchObject({
      status: "blocked",
      reason: "Need a clearer target",
    });
  });
});
