import { describe, expect, it, vi } from "vitest";

import { resolvedIntentSchema, type IntentInput, type SurfaceSnapshot } from "@handsoff/contracts";

import { buildResolveIntentMessages } from "./prompt";
import {
  resolveWithOpenAi,
  type OpenAiIntentClient,
  type OpenAiParsedChoice,
} from "./openai-resolver";
import type { OpenAiResolvedIntent } from "./action-plan-schema";

function surface(overrides: Partial<SurfaceSnapshot> = {}): SurfaceSnapshot {
  return {
    id: "surface-1",
    title: "Codex",
    app: "Codex",
    pid: 42,
    windowId: 7,
    availability: "available",
    accessStatus: "accessible",
    ...overrides,
  };
}

function input(overrides: Partial<IntentInput> = {}): IntentInput {
  const selected = surface();
  return {
    sessionId: "session-1",
    speech: {
      finalTranscript: {
        kind: "final",
        text: "click that button",
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
        surface: selected,
        cursor: { x: 10, y: 20 },
      },
    ],
    surfaceCandidates: [selected],
    ...overrides,
  };
}

function openAiSurface(source: SurfaceSnapshot = surface()) {
  return {
    id: source.id,
    title: source.title,
    app: source.app,
    pid: source.pid ?? null,
    windowId: source.windowId ?? null,
    availability: source.availability,
    accessStatus: source.accessStatus,
  };
}

function readyOutput(overrides: Partial<OpenAiResolvedIntent> = {}): OpenAiResolvedIntent {
  return {
    status: "ready",
    id: "intent-llm",
    intent_type: "click",
    referent: { id: "surface-1", source: "head", confidence: 0.9 },
    constraints: [],
    risk_level: "mutating",
    requires_approval: true,
    target_agent: "cua-driver",
    action_plan: {
      id: "plan-llm",
      summary: "Click the selected target",
      risk_level: "mutating",
      requires_approval: true,
      target_agent: "cua-driver",
      action_plan: [
        {
          id: "step-1",
          kind: "click_element",
          label: "Click selected target",
          target: { surface: openAiSurface(), elementId: null, elementIndex: 0 },
          text: null,
          value: null,
        },
      ],
    },
    reason: null,
    ...overrides,
  };
}

function clientWith(choice: OpenAiParsedChoice) {
  const parse = vi.fn().mockResolvedValue({ choices: [choice] });
  const client: OpenAiIntentClient = { chat: { completions: { parse } } };
  return { client, parse };
}

describe("resolveWithOpenAi", () => {
  it("returns a ready intent from a valid mocked structured completion", async () => {
    const { client, parse } = clientWith({
      finish_reason: "stop",
      message: { parsed: readyOutput() },
    });

    const resolved = await resolveWithOpenAi(input(), {
      client,
      createdAt: "2026-06-22T12:00:00.000Z",
    });

    expect(resolved).toMatchObject({
      status: "ready",
      intent_type: "click",
      referent: { id: "surface-1", source: "head" },
      action_plan: { action_plan: [{ kind: "click_element" }] },
    });
    expect(resolvedIntentSchema.safeParse(resolved).success).toBe(true);
    expect(parse).toHaveBeenCalledWith(expect.objectContaining({ model: "gpt-4o-mini" }));
  });

  it("derives approval from risk instead of trusting model output", async () => {
    const { client } = clientWith({
      finish_reason: "stop",
      message: {
        parsed: readyOutput({
          risk_level: "mutating",
          requires_approval: false,
          action_plan: {
            ...readyOutput().action_plan!,
            risk_level: "mutating",
            requires_approval: false,
          },
        }),
      },
    });

    await expect(resolveWithOpenAi(input(), { client })).resolves.toMatchObject({
      status: "ready",
      risk_level: "mutating",
      requires_approval: true,
      action_plan: {
        risk_level: "mutating",
        requires_approval: true,
      },
    });
  });

  it("normalizes launch-app steps from structured SDK output", async () => {
    const { client } = clientWith({
      finish_reason: "stop",
      message: {
        parsed: readyOutput({
          intent_type: "type_text",
          action_plan: {
            ...readyOutput().action_plan!,
            summary: "Open TextEdit and type dictated text",
            action_plan: [
              {
                id: "step-1",
                kind: "launch_app",
                label: "Open TextEdit",
                appName: "TextEdit",
                bundleId: null,
              },
              {
                id: "step-2",
                kind: "type_text",
                label: "Type dictated text",
                target: { surface: openAiSurface(), elementId: null, elementIndex: 0 },
                text: "hello goodbye",
                value: null,
              },
            ],
          },
        }),
      },
    });

    await expect(resolveWithOpenAi(input(), { client })).resolves.toMatchObject({
      status: "ready",
      action_plan: {
        action_plan: [
          { kind: "launch_app", appName: "TextEdit" },
          { kind: "type_text", text: "hello goodbye" },
        ],
      },
    });
  });

  it("turns an OpenAI refusal into a recoverable clarification", async () => {
    const { client } = clientWith({
      finish_reason: "stop",
      message: { refusal: "I need a clearer target." },
    });

    await expect(resolveWithOpenAi(input(), { client })).resolves.toMatchObject({
      status: "clarification_required",
      reason: "I need a clearer target.",
      target_agent: "none",
    });
  });

  it("treats truncated completions as recoverable clarification", async () => {
    const { client } = clientWith({
      finish_reason: "length",
      message: { parsed: readyOutput() },
    });

    await expect(resolveWithOpenAi(input(), { client })).resolves.toMatchObject({
      status: "clarification_required",
      reason: "The intent resolver response was truncated",
    });
  });

  it("downgrades parsed output that fails the real action-plan contract", async () => {
    const destructive = readyOutput({
      risk_level: "destructive",
      action_plan: {
        ...readyOutput().action_plan!,
        risk_level: "destructive",
      },
    });
    const { client } = clientWith({
      finish_reason: "stop",
      message: { parsed: destructive },
    });

    await expect(resolveWithOpenAi(input(), { client })).resolves.toMatchObject({
      status: "blocked",
      reason: "The intent resolver returned an invalid action plan",
      target_agent: "none",
    });
  });

  it("still calls OpenAI when there are no candidates so app-launch commands can resolve", async () => {
    const { client, parse } = clientWith({
      finish_reason: "stop",
      message: {
        parsed: readyOutput({
          status: "clarification_required",
          intent_type: null,
          referent: null,
          risk_level: null,
          target_agent: "none",
          action_plan: null,
          reason: "No target surface was available",
        }),
      },
    });

    const resolved = await resolveWithOpenAi(
      input({
        surfaceCandidates: [],
        pointingEvidence: [{ source: "head", confidence: 0, strategy: "head-neighborhood-empty" }],
      }),
      { client },
    );

    expect(resolved).toMatchObject({
      status: "clarification_required",
      reason: "No target surface was available",
    });
    expect(parse).toHaveBeenCalled();
  });
});

describe("buildResolveIntentMessages", () => {
  it("sends transcript and candidate surface metadata without camera data", () => {
    const messages = buildResolveIntentMessages(input());
    const payload = JSON.parse(messages[1]!.content);

    expect(payload).toEqual({
      transcript: { text: "click that button", confidence: 0.95 },
      candidateSurfaces: [
        {
          rank: 1,
          id: "surface-1",
          title: "Codex",
          app: "Codex",
          pid: 42,
          windowId: 7,
          availability: "available",
          accessStatus: "accessible",
        },
      ],
    });
    expect(messages[1]!.content).not.toContain("pointingEvidence");
    expect(messages[1]!.content).not.toContain("cursor");
  });
});
