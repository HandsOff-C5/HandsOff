import { createFakeCuaDriver } from "@handsoff/cua";
import type { IntentInput, ResolvedIntent, SurfaceSnapshot } from "@handsoff/contracts";
import { fakeCuaWindowState } from "@handsoff/testkit";
import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { createIntentWorkerResolver, useVoiceCuaController } from "./useVoiceCuaController";
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

function readyType(
  input: IntentInput,
  targetSurface: SurfaceSnapshot,
  text: string,
): ResolvedIntent {
  return {
    status: "ready",
    id: "intent-1",
    input,
    intent_type: "type_text",
    referent: { id: targetSurface.id, source: "fusion", confidence: 1 },
    constraints: [],
    risk_level: "mutating",
    requires_approval: true,
    target_agent: "cua-driver",
    action_plan: {
      id: "plan-1",
      summary: "Type dictated text",
      risk_level: "mutating",
      requires_approval: true,
      target_agent: "cua-driver",
      action_plan: [
        {
          id: "step-1",
          kind: "type_text",
          label: "Type dictated text",
          target: { surface: targetSurface, elementIndex: 0 },
          text,
        },
      ],
    },
    createdAt: NOW,
  };
}

function readyLaunchAndType(
  input: IntentInput,
  appName: string,
  targetSurface: SurfaceSnapshot,
  text: string,
): ResolvedIntent {
  const typed = readyType(input, targetSurface, text);
  return {
    ...typed,
    action_plan: {
      ...typed.action_plan,
      summary: `Open ${appName} and type dictated text`,
      action_plan: [
        { id: "step-1", kind: "launch_app", label: `Open ${appName}`, appName },
        {
          id: "step-2",
          kind: "type_text",
          label: "Type dictated text",
          target: { surface: targetSurface, elementIndex: 0 },
          text,
        },
      ],
    },
  };
}

describe("useVoiceCuaController", () => {
  it("resolves intent through the Tauri Worker proxy client", async () => {
    const invoke = vi.fn(async () => ({
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
    }));
    const input: IntentInput = {
      sessionId: "session-1",
      speech: { finalTranscript },
      pointingEvidence: [{ source: "head", confidence: 0.9, strategy: "head-neighborhood" }],
      surfaceCandidates: [surface()],
    };

    await expect(
      createIntentWorkerResolver(invoke)(input, {
        resolver: "auto",
        createdAt: NOW,
      }),
    ).resolves.toMatchObject({
      status: "blocked",
      reason: "Need a clearer target",
    });
    expect(invoke).toHaveBeenCalledWith("intent_resolve", {
      request: { model: "gpt-4o-mini", messages: expect.any(Array) },
    });
  });

  it("resolves final transcripts with head candidates through auto intent resolution", async () => {
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
    expect(options).toMatchObject({ resolver: "auto", createdAt: NOW });
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

  it("runs a launch-and-type plan for the reported TextEdit command", async () => {
    const textEdit = surface({
      id: "textedit:1",
      title: "Untitled",
      app: "TextEdit",
      pid: 99,
      windowId: 100,
    });
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: textEdit }),
      windows: [textEdit],
    });
    const resolveIntent = vi.fn(async (input: IntentInput) =>
      readyLaunchAndType(input, "TextEdit", surfaceForApp("TextEdit"), "hello goodbye"),
    );
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: { point: null, candidates: [] },
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
      }),
    );

    act(() =>
      result.current.handleFinalTranscript({
        ...finalTranscript,
        text: "Open TextEdit and type hello goodbye",
      }),
    );
    await waitFor(() => expect(result.current.intent?.status).toBe("ready"));

    await act(async () => result.current.approve());

    expect(driver.calls().map((call) => call.kind)).toEqual([
      "launch_app",
      "get_window_state",
      "type_text",
      "get_window_state",
    ]);
    expect(driver.calls()).toContainEqual({
      kind: "type_text",
      target: expect.objectContaining({ surface: expect.objectContaining({ app: "TextEdit" }) }),
      text: "hello goodbye",
    });
    expect(result.current.auditEvents.map((event) => event.kind)).toContain("cua_call");
  });

  it("runs an add-into-this-app transcript as a current-app type action", async () => {
    const active = surface({ id: "codex:active", title: "Codex", app: "Codex" });
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: active }),
      windows: [active],
    });
    const resolveIntent = vi.fn(async (input: IntentInput) =>
      readyType(input, currentAppSurface(), "hello hello goodbye"),
    );
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: { point: null, candidates: [] },
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
      }),
    );

    act(() =>
      result.current.handleFinalTranscript({
        ...finalTranscript,
        text: "Add hello hello goodbye into this app",
      }),
    );
    await waitFor(() => expect(result.current.intent?.status).toBe("ready"));

    await act(async () => result.current.approve());

    expect(result.current.runResult?.status).toBe("succeeded");
    expect(driver.calls()).toContainEqual({
      kind: "type_text",
      target: expect.objectContaining({
        surface: expect.objectContaining({ id: "active-window", app: "Current app" }),
      }),
      text: "hello hello goodbye",
    });
  });
});

function surfaceForApp(appName: string): SurfaceSnapshot {
  return {
    id: `app:${appName.toLowerCase()}`,
    title: appName,
    app: appName,
    availability: "unknown",
    accessStatus: "unknown",
  };
}

function currentAppSurface(): SurfaceSnapshot {
  return {
    id: "active-window",
    title: "Active window",
    app: "Current app",
    availability: "available",
    accessStatus: "accessible",
  };
}
