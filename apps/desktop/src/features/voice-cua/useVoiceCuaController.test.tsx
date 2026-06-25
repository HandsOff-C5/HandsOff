import { createFakeCuaDriver, cuaBlocked, cuaFailed } from "@handsoff/cua";
import type {
  IntentInput,
  PointingCandidate,
  PointingEvidence,
  ResolvedIntent,
  SurfaceSnapshot,
  TranscriptWord,
} from "@handsoff/contracts";
import type { AttentionWindow } from "@handsoff/intent";
import { fakeCuaWindowState } from "@handsoff/testkit";
import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { createIntentWorkerResolver } from "./intentResolver";
import type { PointingContext } from "./buildPointingEvidence";
import { useVoiceCuaController } from "./useVoiceCuaController";
import type { CaptureTrace } from "../capture-trace";
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

// Build a full PointingContext for the consolidated `getPointingContext` prop,
// defaulting every field so a test only sets the signal it exercises.
function pointingContext(partial: Partial<PointingContext> = {}): PointingContext {
  return {
    gestureEvidence: null,
    gestureCursor: null,
    captureTrace: null,
    pointableWindows: [],
    ...partial,
  };
}

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
    // U3b: the loop passes createdAt + the loaded driver tool catalog (tools) to
    // the next-tool-call resolver.
    expect(options).toMatchObject({ createdAt: NOW });
    expect(Array.isArray(options.tools)).toBe(true);
    // Combinative: face-tracker-position entry from headPointing.point + head-neighborhood
    // from the candidate. Both are always included when headPointing is set.
    expect(input.pointingEvidence).toEqual([
      {
        source: "head",
        confidence: 0.5,
        strategy: "face-tracker-position",
        cursor: { x: 10, y: 20 },
      },
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

  it("combines locked gesture evidence with face tracker head evidence", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(async (input: IntentInput) => ready(input));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        getPointingContext: () => pointingContext({ gestureEvidence }),
        headPointing: headPointing(),
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
      }),
    );

    act(() => result.current.handleFinalTranscript(finalTranscript));

    await waitFor(() => expect(result.current.intent?.status).toBe("ready"));
    const input = resolveIntent.mock.calls[0]![0];
    // Combinative: gesture evidence + face-tracker position + head neighborhood all included.
    expect(input.pointingEvidence).toEqual(
      expect.arrayContaining([
        gestureEvidence,
        expect.objectContaining({ source: "head", strategy: "face-tracker-position" }),
        expect.objectContaining({ source: "head", strategy: "head-neighborhood" }),
      ]),
    );
    // Gesture surface candidate always included; head candidate also included.
    expect(input.surfaceCandidates).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: "gesture-target" }),
        expect.objectContaining({ id: surface().id }),
      ]),
    );
    expect(result.current.intent).toMatchObject({
      status: "ready",
      referent: { id: "gesture-target" },
    });
    // U3b: the loop loads the driver tool catalog (list_tools) once before
    // resolving, then perceives (list_windows + get_window_state) and pauses at
    // the mutating-click approval gate — no action dispatched yet.
    expect(driver.calls().map((call) => call.kind)).toEqual([
      "list_windows",
      "get_window_state",
      "list_tools",
    ]);
  });

  it("falls back to the active-window cursor path when no gesture or head snapshot is available", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(async (input: IntentInput) => ready(input));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
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
    // Combinative: with a head point but no candidates, we get face-tracker-position
    // + head-neighborhood-empty (both from headPointing).
    expect(resolveIntent.mock.calls[0]![0]).toMatchObject({
      pointingEvidence: expect.arrayContaining([
        {
          source: "head",
          confidence: 0.5,
          strategy: "face-tracker-position",
          cursor: { x: 10, y: 20 },
        },
        {
          source: "head",
          confidence: 0,
          strategy: "head-neighborhood-empty",
          cursor: { x: 10, y: 20 },
        },
      ]),
      surfaceCandidates: [],
    });

    await act(async () => result.current.approve());
    // Observe + load the tool catalog, then clarify — no action dispatched, and
    // approve() is a no-op against a clarification.
    expect(driver.calls().map((call) => call.kind)).toEqual([
      "list_windows",
      "get_window_state",
      "list_tools",
    ]);
  });

  it("includes gesture cursor evidence when getGestureCursor provides a position", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    // Use headPointing so surfaceCandidates is not empty (ready() requires surfaceCandidates[0]).
    const resolveIntent = vi.fn(async (input: IntentInput) => ready(input));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        getPointingContext: () => pointingContext({ gestureCursor: { x: 0.6, y: 0.4 } }),
        headPointing: headPointing(),
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
      }),
    );

    act(() => result.current.handleFinalTranscript(finalTranscript));

    await waitFor(() => expect(resolveIntent).toHaveBeenCalled());
    const input = resolveIntent.mock.calls[0]![0];
    expect(input.pointingEvidence).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          source: "gesture",
          strategy: "wrist-ray-position",
          cursor: { x: 0.6, y: 0.4 },
        }),
      ]),
    );
  });

  it("always includes head evidence alongside gesture when headPointing is set", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(async (input: IntentInput) => ready(input));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        getPointingContext: () => pointingContext({ gestureCursor: { x: 0.5, y: 0.5 } }),
        headPointing: headPointing(),
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
      }),
    );

    act(() => result.current.handleFinalTranscript(finalTranscript));

    await waitFor(() => expect(resolveIntent).toHaveBeenCalled());
    const input = resolveIntent.mock.calls[0]![0];
    // Both gesture cursor and head evidence are present in the combinative output.
    const sources = input.pointingEvidence.map((e) => e.source);
    expect(sources).toContain("gesture");
    expect(sources).toContain("head");
  });

  it("auto-runs a reversible plan without waiting for approval", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    // tick 0 hands back a reversible (no-approval) click; tick 1 reports the goal
    // satisfied. The loop should execute the click on its own — no approve() call —
    // and settle into a satisfied / succeeded terminal state.
    const reversibleClick = (input: IntentInput): ResolvedIntent => ({
      status: "ready",
      id: "intent-1",
      input,
      intent_type: "click",
      referent: { id: input.surfaceCandidates[0]!.id, source: "head", confidence: 0.9 },
      constraints: [],
      risk_level: "reversible",
      requires_approval: false,
      target_agent: "cua-driver",
      action_plan: {
        id: "plan-1",
        summary: "Click selected target",
        risk_level: "reversible",
        requires_approval: false,
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
    });
    const resolveIntent = vi.fn(
      async (input: IntentInput): Promise<ResolvedIntent> =>
        input.goalSession?.tick === 0 ? reversibleClick(input) : satisfied(input),
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

    // No approve() call — a reversible plan runs on its own and the loop terminates.
    await waitFor(() => expect(result.current.intent?.status).toBe("satisfied"));
    expect(result.current.session?.status).toBe("succeeded");
    // U3b: the click is dispatched through the generic passthrough (driver.call).
    expect(driver.calls().some((call) => call.kind === "call" && call.tool === "click")).toBe(true);
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
    // U3b: the loop loads the tool catalog (list_tools, cached after tick 0),
    // perceives per tick (list_windows + get_window_state), and dispatches the
    // action through the generic passthrough (driver.call) — so the click is a
    // `call` record, not a `click` record.
    expect(driver.calls().map((call) => call.kind)).toEqual([
      "list_windows",
      "get_window_state",
      "list_tools",
      "call",
      "list_windows",
      "get_window_state",
    ]);
    const callStep = driver.calls().find((call) => call.kind === "call");
    expect(callStep).toMatchObject({ kind: "call", tool: "click" });
  });

  it("persists exact fake-CUA permission failures and feeds them back for recovery", async () => {
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: surface() }),
      // U3b: the action is dispatched via driver.call, so the permission failure
      // surfaces as the call result (not the typed-path permission check).
      nextCallResult: cuaBlocked("Accessibility permission denied"),
    });
    // tick 0 → the mutating click (gated); after approval it fails on the denied
    // permission; the loop FEEDS that failure forward (recovery) and asks again
    // at tick 1. A realistic resolver, seeing the OS-permission failure it can't
    // recover from, ends the goal blocked — proving the failure was both audited
    // AND surfaced to the next turn (not a silent hard-abort).
    const resolveIntent = vi.fn(async (input: IntentInput): Promise<ResolvedIntent> => {
      if (input.goalSession?.tick === 0) return ready(input);
      const lastResult = input.goalSession?.observations.at(-1)?.previousAction?.result;
      return {
        status: "blocked",
        id: "intent-cannot-recover",
        input,
        constraints: [],
        requires_approval: false,
        target_agent: "none",
        reason:
          lastResult?.status === "blocked"
            ? `Cannot recover: ${lastResult.reason}`
            : "Cannot recover",
        createdAt: NOW,
      };
    });
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

    // The exact fake-CUA failure is preserved in the audit trail as the per-call
    // tool_call record (U3b recovers from a failed dispatch rather than emitting a
    // terminal execution_finished — that event is now reserved for reject()).
    await waitFor(() => expect(result.current.intent?.status).toBe("blocked"));
    const toolCall = result.current.auditEvents.find((e) => e.kind === "tool_call");
    expect(toolCall).toMatchObject({
      kind: "tool_call",
      tool: "click",
      approval: "approved",
      result: { status: "blocked", reason: "Accessibility permission denied" },
    });
    // The denied-permission failure reached the recovery turn.
    expect(result.current.intent).toMatchObject({
      status: "blocked",
      reason: "Cannot recover: Accessibility permission denied",
    });
    expect(result.current.session?.status).toBe("blocked");
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
        toolCallBudget: 3,
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
    // The mutating type tick has not been dispatched yet (no type_text call).
    expect(driver.calls().some((c) => c.kind === "call" && c.tool === "type_text")).toBe(false);

    await act(async () => result.current.approve());

    await waitFor(() => expect(result.current.intent?.status).toBe("satisfied"));
    expect(result.current.session?.status).toBe("succeeded");
    // U3b: actions dispatch through driver.call (launch_app then type_text); the
    // tool catalog loads once (list_tools, cached). Each tick re-observes.
    expect(driver.calls().map((call) => call.kind)).toEqual([
      "list_windows",
      "get_window_state",
      "list_tools",
      "call",
      "list_windows",
      "get_window_state",
      "call",
      "list_windows",
      "get_window_state",
    ]);
    expect(
      driver
        .calls()
        .filter((c) => c.kind === "call")
        .map((c) => c.tool),
    ).toEqual(["launch_app", "type_text"]);
  });

  it("executes a multi-step plan step-by-step after approval (no one-action-per-tick block)", async () => {
    // U3 removes the `action_plan.length !== 1` block: the agentic loop may now
    // combine actions in a single tick. A mutating multi-step plan still gates
    // for approval; once approved, every step runs in order.
    const notes = surface({ id: "notes:1", title: "Quick Note", app: "Notes" });
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: notes }),
      windows: [notes],
    });
    const resolveIntent = vi.fn(async (input: IntentInput) =>
      input.goalSession?.tick === 0
        ? readyLaunchAndType(input, "Notes", notes, "combined run")
        : satisfied(input, "Notes contains the combined run"),
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
        text: "open Notes and type combined run",
      }),
    );

    // The combined plan is offered (not hard-blocked) and waits for approval.
    await waitFor(() => expect(result.current.intent?.status).toBe("ready"));
    expect(result.current.intent).toMatchObject({
      status: "ready",
      action_plan: { action_plan: [{ kind: "launch_app" }, { kind: "type_text" }] },
    });
    // Nothing dispatched yet.
    expect(driver.calls().some((c) => c.kind === "call")).toBe(false);

    await act(async () => result.current.approve());

    // U3b: both steps dispatch through driver.call, in order, once approved.
    await waitFor(() => expect(result.current.intent?.status).toBe("satisfied"));
    const callTools = driver
      .calls()
      .filter((c) => c.kind === "call")
      .map((c) => c.tool);
    expect(callTools).toContain("launch_app");
    expect(callTools).toContain("type_text");
    expect(callTools.indexOf("launch_app")).toBeLessThan(callTools.indexOf("type_text"));
  });

  it("stops the goal loop at the per-goal action budget", async () => {
    const notes = surface({ id: "notes:1", title: "Quick Note", app: "Notes" });
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: notes }),
      windows: [notes],
    });
    // A resolver that never declares the goal done keeps issuing reversible
    // (auto-running) launches; the per-goal tool-call budget is the backstop
    // that halts a runaway loop with a clear blocked reason.
    const resolveIntent = vi.fn(async (input: IntentInput) => readyLaunchTick(input, "Notes"));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: { point: null, candidates: [] },
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
        toolCallBudget: 2,
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
      reason: "Goal loop reached the action budget of 2",
    });
    expect(result.current.session?.status).toBe("blocked");
    // Two launches ran (budget = 2); the resolver was consulted for each.
    expect(resolveIntent).toHaveBeenCalledTimes(2);
    expect(
      driver.calls().filter((call) => call.kind === "call" && call.tool === "launch_app"),
    ).toHaveLength(2);
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
    // U3b: the current-app type dispatches via driver.call("type_text", …). The
    // active-window surface has no pid/windowId, so the flat args carry just the
    // element_index + text (no pid/window_id).
    const typeCall = driver.calls().find((c) => c.kind === "call" && c.tool === "type_text");
    expect(typeCall).toMatchObject({
      kind: "call",
      tool: "type_text",
      input: { element_index: 0, text: "hello hello goodbye" },
    });
  });
});

// The genuinely-new U3 behaviors: recovery from failure, per-call commit gating
// mid-loop (element-semantics escalation), interrupt, and per-call audit.
describe("U3 autonomous loop", () => {
  it("feeds a failed action forward and recovers instead of ending blocked", async () => {
    const notes = surface({ id: "notes:1", title: "Quick Note", app: "Notes" });
    // The driver fails every action. tick 0 issues a reversible launch (which
    // fails); the loop must NOT terminate — it feeds the failure to tick 1 where
    // the resolver, now seeing the failure, concludes the goal and the loop ends
    // satisfied (recovery), not on a hard-abort.
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: notes }),
      windows: [notes],
      // U3b: actions go through driver.call, so the failure is the call result.
      nextCallResult: cuaFailed("App did not launch"),
    });
    const resolveIntent = vi.fn(async (input: IntentInput): Promise<ResolvedIntent> => {
      if (input.goalSession?.tick === 0) return readyLaunchTick(input, "Notes");
      // tick 1 sees the failure and recovers.
      return satisfied(input, "Recovered after the failed launch");
    });
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: { point: null, candidates: [] },
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
      }),
    );

    act(() => result.current.handleFinalTranscript({ ...finalTranscript, text: "open Notes" }));

    await waitFor(() => expect(result.current.intent?.status).toBe("satisfied"));
    // The loop ran a second resolver turn AFTER the failure (recovery), and the
    // failed result was surfaced to it — not swallowed by a hard-abort.
    expect(resolveIntent).toHaveBeenCalledTimes(2);
    expect(
      resolveIntent.mock.calls[1]![0].goalSession?.observations.at(-1)?.previousAction,
    ).toMatchObject({
      actionId: "plan-open-notes",
      result: { status: "failed", error: "App did not launch" },
    });
    expect(result.current.session?.status).toBe("succeeded");
  });

  it("gates a commit (Send) click mid-loop, runs it after approval", async () => {
    // The perceived window exposes a "Send" control. A bare click on it is NOT
    // navigation — element-semantics escalate it to mutating, so it pauses for
    // approval even if the model declared it reversible.
    const composer = surface({ id: "mail:1", title: "New Message", app: "Mail" });
    const sendState = fakeCuaWindowState({
      surface: composer,
      elementCount: 1,
      elements: [{ id: "send", index: 0, role: "AXButton", label: "Send" }],
    });
    const driver = createFakeCuaDriver({ state: sendState, windows: [composer] });
    const sendClick = (input: IntentInput): ResolvedIntent => ({
      status: "ready",
      id: "intent-send",
      input,
      intent_type: "click",
      // The model declares it reversible — the gate must escalate anyway.
      referent: { id: composer.id, source: "head", confidence: 0.9 },
      constraints: [],
      risk_level: "reversible",
      requires_approval: false,
      target_agent: "cua-driver",
      action_plan: {
        id: "plan-send",
        summary: "Click Send",
        risk_level: "reversible",
        requires_approval: false,
        target_agent: "cua-driver",
        action_plan: [
          {
            id: "step-1",
            kind: "click_element",
            label: "Click Send",
            target: { surface: composer, elementIndex: 0 },
          },
        ],
      },
      createdAt: NOW,
    });
    const resolveIntent = vi.fn(
      async (input: IntentInput): Promise<ResolvedIntent> =>
        input.goalSession?.tick === 0 ? sendClick(input) : satisfied(input, "Message sent"),
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

    act(() => result.current.handleFinalTranscript({ ...finalTranscript, text: "send it" }));

    // Escalated to a pending approval — no click dispatched yet.
    await waitFor(() => expect(result.current.intent?.status).toBe("ready"));
    expect(result.current.intent).toMatchObject({ requires_approval: true });
    expect(driver.calls().some((c) => c.kind === "call" && c.tool === "click")).toBe(false);

    await act(async () => result.current.approve());

    // U3b: after approval the Send click dispatches via driver.call.
    await waitFor(() => expect(result.current.intent?.status).toBe("satisfied"));
    expect(driver.calls().some((c) => c.kind === "call" && c.tool === "click")).toBe(true);
  });

  it("records a per-call tool_call audit event for every executed action", async () => {
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: surface() }),
      windows: [surface()],
    });
    const resolveIntent = vi.fn(
      async (input: IntentInput): Promise<ResolvedIntent> =>
        input.goalSession?.tick === 0 ? readyLaunchTick(input, "Notes") : satisfied(input),
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

    act(() => result.current.handleFinalTranscript({ ...finalTranscript, text: "open Notes" }));

    await waitFor(() => expect(result.current.intent?.status).toBe("satisfied"));
    const toolCalls = result.current.auditEvents.filter((e) => e.kind === "tool_call");
    // The auto-run launch is recorded with transcript provenance + approval state.
    expect(toolCalls).toHaveLength(1);
    expect(toolCalls[0]).toMatchObject({
      kind: "tool_call",
      tool: "launch_app",
      approval: "auto",
      transcript: "open Notes",
      risk: "reversible",
      result: { status: "succeeded" },
    });
  });

  it("interrupt() stops the loop and finishes the session blocked", async () => {
    const notes = surface({ id: "notes:1", title: "Quick Note", app: "Notes" });
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: notes }),
      windows: [notes],
    });
    // A mutating tick that parks at the approval gate, giving us a stable point
    // to interrupt from.
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

    act(() => result.current.interrupt());

    // The pending approval is cleared and the session is terminal-blocked.
    expect(result.current.intent).toMatchObject({ status: "blocked", reason: "Interrupted" });
    expect(result.current.session?.status).toBe("blocked");
    // A later approve() is a no-op — the run is gone.
    const callsBefore = driver.calls().length;
    await act(async () => result.current.approve());
    expect(driver.calls().length).toBe(callsBefore);
  });
});

// U3b: the resolver now emits a generic `tool_call` step naming ANY of the 38
// driver tools (not just the legacy 6 typed kinds), and the loop dispatches it
// through `driver.call(tool, args)` — the U1 passthrough. These tests drive
// tools that were UNREACHABLE before U3b (scroll, kill_app) end-to-end, proving
// (1) a previously-unreachable tool now flows through driver.call with its raw
// args, and (2) the per-call gate still fires off the tool name — a read-only
// tool auto-runs, a destructive tool waits for approval.
describe("U3b full-surface tool_call dispatch", () => {
  // A ready intent carrying a single generic tool_call step, shaped exactly like
  // `nextToolCallToIntent` builds it: risk/approval are derived (here passed in to
  // mirror what `riskForToolName(tool)` yields for the chosen tool).
  function readyToolCall(
    input: IntentInput,
    tool: string,
    args: Record<string, unknown>,
    risk: "read_only" | "reversible" | "mutating" | "destructive_external",
  ): ResolvedIntent {
    const requires = risk === "mutating" || risk === "destructive_external";
    return {
      status: "ready",
      id: "intent-toolcall",
      input,
      intent_type: "inspect",
      referent: null,
      constraints: [],
      risk_level: risk,
      requires_approval: requires,
      target_agent: "cua-driver",
      action_plan: {
        id: "plan-toolcall",
        summary: `Call ${tool}`,
        risk_level: risk,
        requires_approval: requires,
        target_agent: "cua-driver",
        action_plan: [
          { id: "step-toolcall", kind: "tool_call", label: `Call ${tool}`, tool, args },
        ],
      },
      createdAt: NOW,
    };
  }

  it("auto-runs a previously-unreachable read-only tool (scroll) through driver.call", async () => {
    const notes = surface({ id: "notes:1", title: "Long Doc", app: "Notes" });
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: notes }),
      windows: [notes],
    });
    // tick 0 → scroll (read_only, no approval) reaching the FULL driver surface;
    // tick 1 → goal done. `scroll` was unreachable through the old 6-kind path.
    const scrollArgs = { pid: 42, window_id: 7, direction: "down", amount: 5 };
    const resolveIntent = vi.fn(
      async (input: IntentInput): Promise<ResolvedIntent> =>
        input.goalSession?.tick === 0
          ? readyToolCall(input, "scroll", scrollArgs, "read_only")
          : satisfied(input, "Scrolled to reveal the rest"),
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

    act(() => result.current.handleFinalTranscript({ ...finalTranscript, text: "scroll down" }));

    // No approve() — a read-only tool auto-runs and the loop settles satisfied.
    await waitFor(() => expect(result.current.intent?.status).toBe("satisfied"));
    expect(result.current.session?.status).toBe("succeeded");
    // The scroll dispatched through the generic passthrough with its raw args —
    // recorded by the fake driver as a `call`, not a typed `scroll` method.
    const scrollCall = driver.calls().find((c) => c.kind === "call" && c.tool === "scroll");
    expect(scrollCall).toEqual({ kind: "call", tool: "scroll", input: scrollArgs });
    // Audited as a read-only tool_call that auto-ran.
    const toolCall = result.current.auditEvents.find(
      (e) => e.kind === "tool_call" && e.tool === "scroll",
    );
    expect(toolCall).toMatchObject({
      kind: "tool_call",
      tool: "scroll",
      approval: "auto",
      risk: "read_only",
      result: { status: "succeeded" },
    });
  });

  it("gates a previously-unreachable destructive tool (kill_app) until approved, then dispatches it", async () => {
    const notes = surface({ id: "notes:1", title: "Quick Note", app: "Notes" });
    const driver = createFakeCuaDriver({
      state: fakeCuaWindowState({ surface: notes }),
      windows: [notes],
    });
    // kill_app is destructive_external → the gate MUST pause for approval even
    // though it reaches the full surface; only after approve() does it dispatch.
    const killArgs = { pid: 999 };
    const resolveIntent = vi.fn(
      async (input: IntentInput): Promise<ResolvedIntent> =>
        input.goalSession?.tick === 0
          ? readyToolCall(input, "kill_app", killArgs, "destructive_external")
          : satisfied(input, "Force-quit the app"),
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

    act(() => result.current.handleFinalTranscript({ ...finalTranscript, text: "force quit it" }));

    // Paused at the gate — no kill_app call dispatched yet.
    await waitFor(() => expect(result.current.intent?.status).toBe("ready"));
    expect(result.current.intent).toMatchObject({ status: "ready", requires_approval: true });
    expect(driver.calls().some((c) => c.kind === "call" && c.tool === "kill_app")).toBe(false);

    await act(async () => result.current.approve());

    // After approval the destructive tool dispatches through driver.call.
    await waitFor(() => expect(result.current.intent?.status).toBe("satisfied"));
    const killCall = driver.calls().find((c) => c.kind === "call" && c.tool === "kill_app");
    expect(killCall).toEqual({ kind: "call", tool: "kill_app", input: killArgs });
    const toolCall = result.current.auditEvents.find(
      (e) => e.kind === "tool_call" && e.tool === "kill_app",
    );
    expect(toolCall).toMatchObject({
      kind: "tool_call",
      tool: "kill_app",
      approval: "approved",
      risk: "destructive_external",
      result: { status: "succeeded" },
    });
  });
});

// Characterization of the SUPERVISED invariants the U3 autonomous-loop refactor
// must preserve (captured before the refactor, kept after). Each test names one
// of the four invariants the brief calls out:
//   (a) a reversible/read-only plan auto-runs WITHOUT approval
//   (b) a mutating plan WAITS for approve(); reject() runs nothing
//   (c) the loop OBSERVES window state before acting
//   (d) low-confidence / no-candidate → clarification|blocked, never an action
describe("U3 characterization: supervised invariants", () => {
  it("(a) auto-runs a reversible plan with no approve() call", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const reversibleClick = (input: IntentInput): ResolvedIntent => ({
      status: "ready",
      id: "intent-rev",
      input,
      intent_type: "click",
      referent: { id: input.surfaceCandidates[0]!.id, source: "head", confidence: 0.9 },
      constraints: [],
      risk_level: "reversible",
      requires_approval: false,
      target_agent: "cua-driver",
      action_plan: {
        id: "plan-rev",
        summary: "Click selected target",
        risk_level: "reversible",
        requires_approval: false,
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
    });
    const resolveIntent = vi.fn(
      async (input: IntentInput): Promise<ResolvedIntent> =>
        input.goalSession?.tick === 0 ? reversibleClick(input) : satisfied(input),
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

    await waitFor(() => expect(result.current.intent?.status).toBe("satisfied"));
    expect(result.current.session?.status).toBe("succeeded");
    // The click executed without any approve() round-trip (dispatched via driver.call).
    expect(driver.calls().some((call) => call.kind === "call" && call.tool === "click")).toBe(true);
  });

  it("(b) a mutating plan waits for approve(); reject() runs no action", async () => {
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
    // Paused at the gate: no action dispatched yet (no driver.call).
    expect(driver.calls().some((c) => c.kind === "call")).toBe(false);

    await act(async () => result.current.reject());
    // reject() runs nothing (no driver.call) and leaves the session rejected.
    expect(driver.calls().some((c) => c.kind === "call")).toBe(false);
    expect(result.current.session?.status).toBe("rejected");
  });

  it("(c) observes window state before issuing any action", async () => {
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
    // The very first driver interactions are perception (list_windows +
    // get_window_state) — the loop perceives before it acts.
    expect(
      driver
        .calls()
        .slice(0, 2)
        .map((c) => c.kind),
    ).toEqual(["list_windows", "get_window_state"]);
  });

  it("(d) no-candidate clarification never produces an action", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(
      async (input: IntentInput): Promise<ResolvedIntent> => ({
        status: "clarification_required",
        id: "intent-clarify",
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
    // Only perception ran — no action (driver.call) was dispatched.
    expect(driver.calls().some((c) => c.kind === "call")).toBe(false);
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
          toolCallBudget: 3,
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

      // U3b: actions dispatch through driver.call; assert the tool sequence.
      const actionCalls = driver
        .calls()
        .filter((call) => call.kind === "call")
        .map((call) => call.tool)
        .filter((tool) => tool === "launch_app" || tool === "type_text");
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

// U7: the capture trace (U5) + per-word timings (U4) feed the temporal binder
// (U6) inside createIntent, so each deictic word binds to the surface pointed at
// while it was spoken — multiple targets in one utterance reach surfaceCandidates
// and the prompt. The fallback (no trace/words) leaves the single end-of-speech
// snapshot as the sole signal, exactly as before.
describe("U7 temporal multi-target binding into IntentInput", () => {
  // Two displays as pointable windows: Notes on the left, Slack on the right. A
  // hand candidate's targetId is a window/surface id; the binder resolves it here.
  const notesSurface: SurfaceSnapshot = {
    id: "win-notes",
    title: "Notes",
    app: "Notes",
    availability: "available",
    accessStatus: "accessible",
  };
  const slackSurface: SurfaceSnapshot = {
    id: "win-slack",
    title: "Slack",
    app: "Slack",
    availability: "available",
    accessStatus: "accessible",
  };
  const pointableWindows: readonly AttentionWindow[] = [
    { surface: notesSurface, bounds: { x: 0, y: 0, width: 400, height: 400 } },
    { surface: slackSurface, bounds: { x: 1000, y: 0, width: 400, height: 400 } },
  ];

  function word(text: string, startMs: number, endMs: number): TranscriptWord {
    return { text, startMs, endMs, confidence: 0.9 };
  }

  function handAt(tsMs: number, targetId: string): CaptureTrace["handTrace"][number] {
    const candidate: PointingCandidate = { targetId, confidence: 0.85, calibrationQuality: "good" };
    return {
      x: targetId === "win-notes" ? 200 : 1200,
      y: 200,
      candidate,
      phase: "locked",
      tsMs,
    };
  }

  // "type Laura in THIS [@1000–1300] and hello goodbye in THAT [@9000–9300]" with
  // the hand pointing at Notes while "this" was spoken and Slack while "that" was.
  const twoTargetWords: readonly TranscriptWord[] = [
    word("type", 100, 300),
    word("Laura", 300, 600),
    word("in", 600, 800),
    word("this", 1000, 1300),
    word("and", 8000, 8200),
    word("hello", 8200, 8500),
    word("goodbye", 8500, 8900),
    word("in", 8900, 9000),
    word("that", 9000, 9300),
  ];
  const twoTargetTrace: CaptureTrace = {
    headTrace: [],
    handTrace: [handAt(1100, "win-notes"), handAt(9100, "win-slack")],
    words: twoTargetWords,
  };

  const twoTargetTranscript = {
    kind: "final" as const,
    text: "type Laura in this and hello goodbye in that",
    confidence: 0.95,
    latencyMs: 100,
    receivedAt: 1,
    words: twoTargetWords,
  };

  it("binds two deictic words to two distinct surfaces in surfaceCandidates and pointingEvidence", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(async (input: IntentInput) => satisfied(input, "bound"));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: { point: null, candidates: [] },
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
        getPointingContext: () =>
          pointingContext({ captureTrace: twoTargetTrace, pointableWindows }),
      }),
    );

    act(() => result.current.handleFinalTranscript(twoTargetTranscript));

    await waitFor(() => expect(resolveIntent).toHaveBeenCalled());
    const input = resolveIntent.mock.calls[0]![0];

    // Both bound surfaces reach the loop as candidates, so it can target each
    // across successive ticks ("type X in this … type Y in that").
    const candidateIds = input.surfaceCandidates.map((s) => s.id);
    expect(candidateIds).toContain("win-notes");
    expect(candidateIds).toContain("win-slack");

    // Each deictic produced its own fusion (temporal-bind) evidence, stamped with
    // the bound word + the sample timestamp.
    const fusion = input.pointingEvidence.filter((e) => e.source === "fusion");
    expect(fusion).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          source: "fusion",
          strategy: "temporal-bind:this@1100",
          surface: expect.objectContaining({ id: "win-notes" }),
        }),
        expect.objectContaining({
          source: "fusion",
          strategy: "temporal-bind:that@9100",
          surface: expect.objectContaining({ id: "win-slack" }),
        }),
      ]),
    );
    // The two bound referents are distinct surfaces (the Notes/Slack case).
    const fusionIds = fusion.map((e) => e.surface?.id);
    expect(new Set(fusionIds).size).toBe(2);
  });

  it("carries the bound-referent confidence into the built next-tool-call prompt", async () => {
    // Capture the messages the resolver was handed by routing through the real
    // worker-proxy resolver: it serializes buildNextToolCallMessages into the
    // invoke payload, so we can assert the bound referents reached the model.
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const invoke = vi.fn(async () => ({
      choices: [{ finish_reason: "stop", message: { parsed: { status: "done", summary: "ok" } } }],
    }));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: { point: null, candidates: [] },
        now: () => NOW,
        resolveIntent: createIntentWorkerResolver(invoke),
        targetResolveDelayMs: 0,
        getPointingContext: () =>
          pointingContext({ captureTrace: twoTargetTrace, pointableWindows }),
      }),
    );

    act(() => result.current.handleFinalTranscript(twoTargetTranscript));

    await waitFor(() => expect(invoke).toHaveBeenCalled());
    const { request } = invoke.mock.calls[0]![1] as {
      request: { messages: { role: string; content: string }[] };
    };
    const userPayload = JSON.parse(request.messages[1]!.content);
    expect(userPayload.boundReferents).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ word: "this", surfaceId: "win-notes", confidence: 0.85 }),
        expect.objectContaining({ word: "that", surfaceId: "win-slack", confidence: 0.85 }),
      ]),
    );
  });

  it("falls back to the end-of-speech snapshot when there is no trace (non-binding flow unchanged)", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(async (input: IntentInput) => ready(input));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: headPointing(),
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
        // No captureTrace → the binder never runs.
        getPointingContext: () => pointingContext({ pointableWindows }),
      }),
    );

    act(() => result.current.handleFinalTranscript(finalTranscript));

    await waitFor(() => expect(resolveIntent).toHaveBeenCalled());
    const input = resolveIntent.mock.calls[0]![0];
    // No fusion (bound) evidence — identical to today's head-snapshot path.
    expect(input.pointingEvidence.some((e) => e.source === "fusion")).toBe(false);
    expect(input.pointingEvidence).toEqual([
      {
        source: "head",
        confidence: 0.5,
        strategy: "face-tracker-position",
        cursor: { x: 10, y: 20 },
      },
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

  it("falls back to the snapshot when a trace exists but the transcript carries no words", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState({ surface: surface() }) });
    const resolveIntent = vi.fn(async (input: IntentInput) => ready(input));
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        headPointing: headPointing(),
        now: () => NOW,
        resolveIntent,
        targetResolveDelayMs: 0,
        // A trace with samples but NO words on either the trace or the transcript →
        // the binder has nothing to align against, so nothing binds.
        getPointingContext: () =>
          pointingContext({
            captureTrace: { headTrace: [], handTrace: [handAt(1100, "win-notes")], words: [] },
            pointableWindows,
          }),
      }),
    );

    act(() => result.current.handleFinalTranscript(finalTranscript));

    await waitFor(() => expect(resolveIntent).toHaveBeenCalled());
    const input = resolveIntent.mock.calls[0]![0];
    expect(input.pointingEvidence.some((e) => e.source === "fusion")).toBe(false);
    expect(input.surfaceCandidates).toEqual([surface()]);
  });
});
