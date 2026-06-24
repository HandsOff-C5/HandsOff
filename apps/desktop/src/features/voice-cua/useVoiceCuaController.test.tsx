import { createFakeCuaDriver } from "@handsoff/cua";
import type {
  IntentInput,
  PointingEvidence,
  ResolvedIntent,
  SurfaceSnapshot,
} from "@handsoff/contracts";
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

const gestureEvidence: PointingEvidence = {
  source: "gesture",
  confidence: 0.9,
  strategy: "wrist-ray-calibrated:good",
  surface: surface({
    id: "gesture-target",
    title: "Pointed window",
    app: "Demo",
  }),
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

function readyLaunchTick(input: IntentInput, appName: string): ResolvedIntent {
  return {
    status: "ready",
    id: `intent-open-${appName.toLowerCase()}`,
    input,
    intent_type: "launch",
    referent: null,
    constraints: [],
    risk_level: "reversible",
    requires_approval: false,
    target_agent: "cua-driver",
    action_plan: {
      id: `plan-open-${appName.toLowerCase()}`,
      summary: `Open ${appName}`,
      risk_level: "reversible",
      requires_approval: false,
      target_agent: "cua-driver",
      action_plan: [{ id: "step-open", kind: "launch_app", label: `Open ${appName}`, appName }],
    },
    createdAt: NOW,
  };
}

function satisfied(input: IntentInput, summary = "Goal satisfied"): ResolvedIntent {
  return {
    status: "satisfied",
    id: "intent-satisfied",
    input,
    requires_approval: false,
    target_agent: "none",
    summary,
    createdAt: NOW,
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

  it("binds locked gesture evidence before head candidates", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(async (input: IntentInput) => ready(input));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        getGestureEvidence: () => gestureEvidence,
        headPointing: headPointing(),
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
      }),
    );

    act(() => result.current.handleFinalTranscript(finalTranscript));

    await waitFor(() => expect(result.current.intent?.status).toBe("ready"));
    expect(resolveIntent.mock.calls[0]![0]).toMatchObject({
      pointingEvidence: [gestureEvidence],
      surfaceCandidates: [gestureEvidence.surface],
    });
    expect(result.current.intent).toMatchObject({
      status: "ready",
      referent: { id: "gesture-target" },
    });
    expect(driver.calls().map((call) => call.kind)).toEqual(["list_windows", "get_window_state"]);
  });

  it("falls back to the active-window cursor path when no gesture or head snapshot is available", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(async (input: IntentInput) => ready(input));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        getGestureEvidence: () => null,
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
      }),
    );

    act(() => result.current.handleFinalTranscript(finalTranscript));

    await waitFor(() => expect(result.current.intent?.status).toBe("ready"));
    expect(resolveIntent.mock.calls[0]![0]).toMatchObject({
      pointingEvidence: [
        {
          source: "cursor",
          confidence: 1,
          strategy: "active-window-current-cursor",
          surface: surface(),
        },
      ],
      surfaceCandidates: [surface()],
    });
    expect(driver.calls().some((call) => call.kind === "get_window_state")).toBe(true);
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
    expect(driver.calls().map((call) => call.kind)).toEqual(["list_windows", "get_window_state"]);
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
    const resolveIntent = vi.fn(async (input: IntentInput) =>
      input.goalSession?.tick === 0 ? ready(input) : satisfied(input),
    );
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
      "list_windows",
      "get_window_state",
      "get_window_state",
      "click",
      "get_window_state",
      "list_windows",
      "get_window_state",
    ]);
  });

  it("persists exact fake-CUA permission failures to the session audit trail", async () => {
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: surface() }),
      permissions: {
        accessibility: "denied",
        screenRecording: "granted",
        driver: "running",
      },
    });
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

    expect(result.current.runResult).toEqual({
      status: "blocked",
      result: { status: "blocked", reason: "Accessibility permission denied" },
    });
    expect(result.current.auditEvents.at(-1)).toMatchObject({
      kind: "execution_finished",
      status: "blocked",
      result: { status: "blocked", reason: "Accessibility permission denied" },
    });
  });

  it("iterates a multi-step goal as observed one-action ticks and gates the mutating tick", async () => {
    const notes = surface({ id: "notes:1", title: "Quick Note", app: "Notes" });
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: notes }),
      windows: [notes],
    });
    const resolveIntent = vi.fn(async (input: IntentInput) => {
      if (input.goalSession?.tick === 0) return readyLaunchTick(input, "Notes");
      if (input.goalSession?.tick === 1) return readyType(input, notes, "hello from the loop");
      return satisfied(input, "Notes contains the dictated idea");
    });
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: { point: null, candidates: [] },
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
        maxGoalTicks: 3,
      }),
    );

    act(() =>
      result.current.handleFinalTranscript({
        ...finalTranscript,
        text: "dump hello from the loop into Notes",
      }),
    );

    await waitFor(() => expect(resolveIntent).toHaveBeenCalledTimes(2));
    expect(resolveIntent.mock.calls[0]![0].goalSession).toMatchObject({
      goal: "dump hello from the loop into Notes",
      tick: 0,
      observations: [{ tick: 0, windows: [notes] }],
    });
    expect(resolveIntent.mock.calls[1]![0].goalSession).toMatchObject({
      tick: 1,
      observations: [
        { tick: 0, windows: [notes] },
        { tick: 1, windows: [notes], previousAction: { actionId: "plan-open-notes" } },
      ],
    });
    expect(result.current.intent).toMatchObject({
      status: "ready",
      requires_approval: true,
      action_plan: { action_plan: [{ kind: "type_text" }] },
    });
    expect(driver.calls().map((call) => call.kind)).not.toContain("type_text");

    await act(async () => result.current.approve());

    await waitFor(() => expect(result.current.intent?.status).toBe("satisfied"));
    expect(result.current.session?.status).toBe("succeeded");
    expect(driver.calls().map((call) => call.kind)).toEqual([
      "list_windows",
      "get_window_state",
      "launch_app",
      "list_windows",
      "get_window_state",
      "get_window_state",
      "type_text",
      "get_window_state",
      "list_windows",
      "get_window_state",
    ]);
  });

  it("blocks next-action resolution that returns a pre-baked multi-step plan", async () => {
    const notes = surface({ id: "notes:1", title: "Quick Note", app: "Notes" });
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: notes }),
      windows: [notes],
    });
    const resolveIntent = vi.fn(async (input: IntentInput) =>
      readyLaunchAndType(input, "Notes", notes, "do not run"),
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
        text: "open Notes and type do not run",
      }),
    );

    await waitFor(() => expect(result.current.intent?.status).toBe("blocked"));
    expect(result.current.intent).toMatchObject({
      status: "blocked",
      reason: "Next-action resolver must return exactly one action per tick; got 2",
    });
    expect(result.current.session?.status).toBe("blocked");
    expect(driver.calls().map((call) => call.kind)).not.toContain("launch_app");
    expect(driver.calls().map((call) => call.kind)).not.toContain("type_text");
  });

  it("stops the goal loop at the max-tick safety bound", async () => {
    const notes = surface({ id: "notes:1", title: "Quick Note", app: "Notes" });
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: notes }),
      windows: [notes],
    });
    const resolveIntent = vi.fn(async (input: IntentInput) => readyLaunchTick(input, "Notes"));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: { point: null, candidates: [] },
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
        maxGoalTicks: 2,
      }),
    );

    act(() =>
      result.current.handleFinalTranscript({
        ...finalTranscript,
        text: "keep opening Notes forever",
      }),
    );

    await waitFor(() => expect(result.current.intent?.status).toBe("blocked"));
    expect(result.current.intent).toMatchObject({
      status: "blocked",
      reason: "Goal loop reached the max-tick safety bound (2)",
    });
    expect(result.current.session?.status).toBe("blocked");
    expect(resolveIntent).toHaveBeenCalledTimes(2);
    expect(driver.calls().filter((call) => call.kind === "launch_app")).toHaveLength(2);
  });

  it("runs an add-into-this-app transcript as a current-app type action", async () => {
    const active = surface({ id: "codex:active", title: "Codex", app: "Codex" });
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: active }),
      windows: [active],
    });
    const resolveIntent = vi.fn(async (input: IntentInput) =>
      input.goalSession?.tick === 0
        ? readyType(input, currentAppSurface(), "hello hello goodbye")
        : satisfied(input),
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

describe("ADR 0006 goal-loop golden evals", () => {
  const goldens = [
    {
      id: "adr-0006-task-05-dump-text-into-notes",
      transcript: "dump this text into Notes",
      expectedActions: ["launch_app", "type_text"],
      terminalStatus: "satisfied",
    },
  ] as const;

  for (const golden of goldens) {
    it(`${golden.id} reaches a terminal state through iteration, not a pre-baked plan`, async () => {
      const notes = surface({ id: "notes:1", title: "Quick Note", app: "Notes" });
      const driver = createFakeCuaDriver({
        state: fakeCuaWindowState({ surface: notes }),
        windows: [notes],
      });
      const resolveIntent = vi.fn(async (input: IntentInput) => {
        if (input.goalSession?.tick === 0) return readyLaunchTick(input, "Notes");
        if (input.goalSession?.tick === 1) return readyType(input, notes, golden.transcript);
        return satisfied(input, "Notes contains the dictated text");
      });
      const { result } = renderHook(() =>
        useVoiceCuaController({
          driver,
          headPointing: { point: null, candidates: [] },
          now: () => NOW,
          resolveIntent,
          targetResolveDelayMs: 0,
          maxGoalTicks: 3,
        }),
      );

      act(() =>
        result.current.handleFinalTranscript({
          ...finalTranscript,
          text: golden.transcript,
        }),
      );
      await waitFor(() => expect(result.current.intent?.status).toBe("ready"));
      await act(async () => result.current.approve());
      await waitFor(() => expect(result.current.intent?.status).toBe(golden.terminalStatus));

      const actionCalls = driver
        .calls()
        .map((call) => call.kind)
        .filter((kind) => kind === "launch_app" || kind === "type_text");
      expect(actionCalls).toEqual([...golden.expectedActions]);
      for (const [input] of resolveIntent.mock.calls) {
        expect(input.goalSession?.observations.at(-1)?.tick).toBe(input.goalSession?.tick);
      }
    });
  }
});

function currentAppSurface(): SurfaceSnapshot {
  return {
    id: "active-window",
    title: "Active window",
    app: "Current app",
    availability: "available",
    accessStatus: "accessible",
  };
}
