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

  it("defaults to the llm resolver so natural language is model-parsed first", async () => {
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
                      reason: "LLM handled the default path",
                    },
                  },
                },
              ],
            };
          },
        },
      },
    };

    await expect(
      resolveIntent(input(), {
        client,
        createdAt: "2026-06-22T12:00:00.000Z",
      }),
    ).resolves.toMatchObject({
      status: "blocked",
      reason: "LLM handled the default path",
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

  it("auto mode uses the llm result before any rule parsing", async () => {
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
                      reason: "LLM handled the supported-looking wording",
                    },
                  },
                },
              ],
            };
          },
        },
      },
    };

    await expect(
      resolveIntent(input("click there"), { resolver: "auto", client }),
    ).resolves.toMatchObject({
      status: "blocked",
      reason: "LLM handled the supported-looking wording",
    });
  });

  it("auto mode falls back to the rule path only when the model call fails", async () => {
    const client: OpenAiIntentClient = {
      chat: {
        completions: {
          async parse() {
            throw new Error("missing API key");
          },
        },
      },
    };

    await expect(
      resolveIntent(input("click there"), {
        resolver: "auto",
        client,
        intentId: "intent-fallback",
        planId: "plan-fallback",
        createdAt: "2026-06-22T12:00:00.000Z",
      }),
    ).resolves.toMatchObject({
      status: "ready",
      id: "intent-fallback",
      action_plan: { id: "plan-fallback", action_plan: [{ kind: "click_element" }] },
    });
  });

  it("auto mode keeps the model failure when fallback cannot parse the command", async () => {
    const client: OpenAiIntentClient = {
      chat: {
        completions: {
          async parse() {
            throw new Error("missing API key");
          },
        },
      },
    };

    await expect(
      resolveIntent(input("Add hello hello goodbye into this app"), {
        resolver: "auto",
        client,
      }),
    ).resolves.toMatchObject({
      status: "blocked",
      reason: "Intent resolver failed: missing API key",
    });
  });

  it("llm mode does not fall back when the model call fails", async () => {
    const client: OpenAiIntentClient = {
      chat: {
        completions: {
          async parse() {
            throw new Error("missing API key");
          },
        },
      },
    };

    await expect(
      resolveIntent(input("click there"), { resolver: "llm", client }),
    ).resolves.toMatchObject({
      status: "blocked",
      reason: "Intent resolver failed: missing API key",
    });
  });
});
