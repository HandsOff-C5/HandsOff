import { createFakeCuaDriver } from "@handsoff/cua";
import type { IntentInput, ResolvedIntent, SurfaceSnapshot } from "@handsoff/contracts";
import { fakeCuaWindowState } from "@handsoff/testkit";
import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { useVoiceCuaController } from "./useVoiceCuaController";
import type { HeadPointingSnapshot } from "../head-pointing/useHeadPointing";

const NOW = "2026-06-22T12:00:00.000Z";

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

function headPointing(candidateSurface = surface()): HeadPointingSnapshot {
  return {
    point: { x: 10, y: 20 },
    candidates: [{ surface: candidateSurface, score: 0.9, distance: 0 }],
  };
}

const finalTranscript = {
  kind: "final" as const,
  text: "click that",
  confidence: 0.95,
  latencyMs: 100,
  receivedAt: 1,
};

function ready(input: IntentInput): ResolvedIntent {
  return {
    status: "ready",
    id: "intent-1",
    input,
    intent_type: "click",
    referent: { id: input.surfaceCandidates[0]!.id, source: "head", confidence: 0.9 },
    constraints: [],
    risk_level: "mutating",
    requires_approval: true,
    target_agent: "cua-driver",
    action_plan: {
      id: "plan-1",
      summary: "Click selected target",
      risk_level: "mutating",
      requires_approval: true,
      target_agent: "cua-driver",
      action_plan: [
        {
          id: "step-1",
          kind: "click_element",
          label: "Click selected target",
          target: { surface: input.surfaceCandidates[0]!, elementIndex: 0 },
        },
      ],
    },
    createdAt: NOW,
  };
}

describe("useVoiceCuaController", () => {
  it("resolves final transcripts with head candidates through the local rule resolver by default", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(async (input: IntentInput) => ready(input));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: headPointing(),
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
      }),
    );

    act(() => result.current.handleFinalTranscript(finalTranscript));

    await waitFor(() => expect(resolveIntent).toHaveBeenCalled());
    const [input, options] = resolveIntent.mock.calls[0]!;
    expect(options).toMatchObject({ resolver: "rule", createdAt: NOW });
    expect(input.pointingEvidence).toEqual([
      {
        source: "head",
        confidence: 0.9,
        strategy: "head-neighborhood",
        surface: surface(),
        cursor: { x: 10, y: 20 },
      },
    ]);
    expect(input.surfaceCandidates).toEqual([surface()]);
  });

  it("does not execute a plan when no candidates produce clarification", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(
      async (input: IntentInput): Promise<ResolvedIntent> => ({
        status: "clarification_required",
        id: "intent-1",
        input,
        constraints: [],
        requires_approval: false,
        target_agent: "none",
        reason: "No attention-region candidates were available",
        createdAt: NOW,
      }),
    );
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: { point: { x: 10, y: 20 }, candidates: [] },
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
      }),
    );

    act(() => result.current.handleFinalTranscript(finalTranscript));

    await waitFor(() => expect(result.current.intent?.status).toBe("clarification_required"));
    expect(resolveIntent.mock.calls[0]![0]).toMatchObject({
      pointingEvidence: [
        {
          source: "head",
          confidence: 0,
          strategy: "head-neighborhood-empty",
          cursor: { x: 10, y: 20 },
        },
      ],
      surfaceCandidates: [],
    });

    await act(async () => result.current.approve());
    expect(driver.calls()).toEqual([]);
  });

  it("uses candidates that arrive during the resolve delay", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(async (input: IntentInput) => ready(input));
    const { result, rerender } = renderHook(
      ({ snapshot }: { snapshot: HeadPointingSnapshot }) =>
        useVoiceCuaController({
          driver,
          headPointing: snapshot,
          now: () => NOW,
          resolveIntent,
          targetResolveDelayMs: 10,
        }),
      { initialProps: { snapshot: { point: null, candidates: [] } } },
    );

    act(() => result.current.handleFinalTranscript(finalTranscript));
    rerender({ snapshot: headPointing() });

    await waitFor(() => expect(resolveIntent).toHaveBeenCalled());
    expect(resolveIntent.mock.calls[0]![0].surfaceCandidates).toEqual([surface()]);
  });

  it("preserves approval through CUA execution and supervision", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(async (input: IntentInput) => ready(input));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: headPointing(),
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
      }),
    );

    act(() => result.current.handleFinalTranscript(finalTranscript));
    await waitFor(() => expect(result.current.intent?.status).toBe("ready"));

    await act(async () => result.current.approve());

    expect(result.current.runResult?.status).toBe("succeeded");
    expect(driver.calls().map((call) => call.kind)).toEqual([
      "get_window_state",
      "click",
      "get_window_state",
    ]);
  });
});
