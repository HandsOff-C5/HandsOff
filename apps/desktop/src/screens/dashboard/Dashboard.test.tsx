import { APP_NAME } from "@handsoff/contracts";
import type { IntentInput, ResolvedIntent, SurfaceSnapshot } from "@handsoff/contracts";
import { createFakeCuaDriver } from "@handsoff/cua";
import { fuseIntent, type ResolveIntentOptions } from "@handsoff/intent";
import { FakeSttStream, fakeCuaWindowState } from "@handsoff/testkit";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { App } from "../../App";
import { Dashboard } from "./Dashboard";

const PANEL_TITLES = [
  "Readiness",
  "Permissions",
  "Settings",
  "Transcript",
  "Sessions",
  "Referents",
  "Plan preview",
];
// Sessions, Referents, and Plan preview still start empty before a transcript arrives.
const EMPTY_PANEL_TITLES = ["Sessions", "Referents", "Plan preview"];

let fakes: FakeSttStream[];

function makeFactory() {
  fakes = [];
  return () => {
    const fake = new FakeSttStream();
    fakes.push(fake);
    return fake;
  };
}

function latest() {
  const fake = fakes[fakes.length - 1];
  if (!fake) throw new Error("no fake stream created");
  return fake;
}

async function flush() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

function talkButton() {
  return screen.getByRole("button", { name: /Hold to talk|Release to send/ });
}

function headPointing(surface: SurfaceSnapshot) {
  return {
    point: { x: 10, y: 20 },
    candidates: [{ surface, score: 0.9, distance: 0 }],
  };
}

async function ruleResolver(input: IntentInput, options: ResolveIntentOptions) {
  return fuseIntent(input, { createdAt: options.createdAt });
}

async function oneTickRuleResolver(
  input: IntentInput,
  options: ResolveIntentOptions,
): Promise<ResolvedIntent> {
  if ((input.goalSession?.tick ?? 0) > 0) {
    return {
      status: "satisfied",
      id: "intent-satisfied",
      input,
      requires_approval: false,
      target_agent: "none",
      summary: "Goal satisfied",
      createdAt: options.createdAt ?? "2026-06-22T12:00:00.000Z",
    };
  }
  return ruleResolver(input, options);
}

beforeEach(() => {
  fakes = [];
});

describe("Dashboard", () => {
  it("mounts without crashing", () => {
    expect(() => render(<Dashboard />)).not.toThrow();
  });

  it("shows the app brand in the header", () => {
    render(<Dashboard />);
    expect(screen.getByRole("heading", { level: 1, name: APP_NAME })).toBeInTheDocument();
  });

  it("renders a panel for each core-loop concern (no blank state)", () => {
    render(<Dashboard />);
    for (const title of PANEL_TITLES) {
      expect(screen.getByRole("heading", { level: 2, name: title })).toBeInTheDocument();
    }
  });

  it("renders empty-state copy before a transcript creates a plan", () => {
    render(<Dashboard />);
    expect(screen.getAllByText(/yet\./i)).toHaveLength(EMPTY_PANEL_TITLES.length);
  });

  it("renders the live readiness panel with capability rows", () => {
    render(<Dashboard />);
    // Without a native backend the panel still shows every capability.
    expect(screen.getByText("Computer-use agent")).toBeInTheDocument();
  });

  it("wires the permissions re-check button to the shared probe", () => {
    render(<Dashboard />);
    // The button is present and clicking it is safe with no native backend
    // (the probe is a no-op), proving the hook → panel wiring holds.
    const recheck = screen.getByRole("button", { name: "Re-check" });
    expect(() => fireEvent.click(recheck)).not.toThrow();
  });

  it("composes the dashboard into the app shell", () => {
    expect(() => render(<App />)).not.toThrow();
    expect(screen.getByRole("heading", { level: 1, name: APP_NAME })).toBeInTheDocument();
  });

  it("turns a final transcript into an approved CUA action", async () => {
    const clock = vi.spyOn(Date, "now").mockReturnValue(1000);
    const state = fakeCuaWindowState();
    const driver = createFakeCuaDriver({ state });
    try {
      render(
        <Dashboard
          createStream={makeFactory()}
          cuaDriver={driver}
          headPointing={headPointing(state.surface)}
          now={() => "2026-06-22T12:00:00.000Z"}
          resolveIntent={oneTickRuleResolver}
          targetResolveDelayMs={0}
        />,
      );

      fireEvent.pointerDown(talkButton());
      await flush();
      act(() => latest().emitFinal("click there", 0.95, 100));
      clock.mockReturnValue(1400);
      fireEvent.pointerUp(talkButton());
      await flush();

      // "Click selected target" appears in both PlanPreviewPanel and ReferentsPanel action plan
      expect(screen.getAllByText("Click selected target").length).toBeGreaterThan(0);
      expect(screen.getByText("session-1")).toBeInTheDocument();
      fireEvent.click(screen.getByRole("button", { name: "Approve" }));

      await waitFor(() => expect(screen.getAllByText("succeeded").length).toBeGreaterThan(0));
      // U3b: the loop dispatches the click through the generic passthrough
      // (driver.call → recorded as a `call`), and perceives once per tick — no
      // per-step pre/post window captures from the old typed executor.
      expect(driver.calls().map((call) => call.kind)).toEqual([
        "list_windows",
        "get_window_state",
        "list_tools",
        "call",
        "list_windows",
        "get_window_state",
      ]);
      expect(driver.calls().find((call) => call.kind === "call")).toMatchObject({
        kind: "call",
        tool: "click",
      });
    } finally {
      clock.mockRestore();
    }
  });

  it("shows CUA recovery guidance while preserving the exact fake-CUA failure", async () => {
    const clock = vi.spyOn(Date, "now").mockReturnValue(1000);
    const state = fakeCuaWindowState();
    // U3b: the loop dispatches the click through driver.call, so the permission
    // failure surfaces from the generic call path. A realistic resolver that
    // can't recover from a denied OS permission ends the goal blocked after
    // seeing the failure (tick 1), keeping the guidance on screen.
    const driver = createFakeCuaDriver({
      state,
      nextCallResult: { status: "blocked", reason: "Accessibility permission denied" },
    });
    const denyThenStop = async (
      input: IntentInput,
      options: ResolveIntentOptions,
    ): Promise<ResolvedIntent> => {
      if ((input.goalSession?.tick ?? 0) === 0) return ruleResolver(input, options);
      return {
        status: "blocked",
        id: "intent-cannot-recover",
        input,
        constraints: [],
        requires_approval: false,
        target_agent: "none",
        reason: "Cannot recover from a denied permission",
        createdAt: options.createdAt ?? "2026-06-22T12:00:00.000Z",
      };
    };
    try {
      render(
        <Dashboard
          createStream={makeFactory()}
          cuaDriver={driver}
          headPointing={headPointing(state.surface)}
          now={() => "2026-06-22T12:00:00.000Z"}
          resolveIntent={denyThenStop}
          targetResolveDelayMs={0}
        />,
      );

      fireEvent.pointerDown(talkButton());
      await flush();
      act(() => latest().emitFinal("click there", 0.95, 100));
      clock.mockReturnValue(1400);
      fireEvent.pointerUp(talkButton());
      await flush();

      fireEvent.click(await screen.findByRole("button", { name: "Approve" }));

      expect(
        await screen.findAllByText(
          "HandsOff needs Accessibility permission before it can control the selected app. Enable Accessibility for HandsOff, then re-check readiness and retry.",
        ),
      ).not.toHaveLength(0);
    } finally {
      clock.mockRestore();
    }
  });

  it("waits before resolving the CUA target after speech release", async () => {
    const clock = vi.spyOn(Date, "now").mockReturnValue(1000);
    const state = fakeCuaWindowState();
    const driver = createFakeCuaDriver({ state });
    try {
      render(
        <Dashboard
          createStream={makeFactory()}
          cuaDriver={driver}
          headPointing={headPointing(state.surface)}
          now={() => "2026-06-22T12:00:00.000Z"}
          resolveIntent={ruleResolver}
          targetResolveDelayMs={10}
        />,
      );

      fireEvent.pointerDown(talkButton());
      await flush();
      act(() => latest().emitFinal("click there", 0.95, 100));
      clock.mockReturnValue(1400);
      fireEvent.pointerUp(talkButton());
      await flush();

      expect(driver.calls()).toHaveLength(0);
      await act(async () => {
        await new Promise((resolve) => setTimeout(resolve, 20));
      });

      // "Click selected target" appears in both PlanPreviewPanel and ReferentsPanel action plan
      expect(screen.getAllByText("Click selected target").length).toBeGreaterThan(0);
      // The goal loop observes the active window (list_windows + get_window_state)
      // and loads the driver tool catalog (list_tools, U3b) before stopping at
      // the approval gate, so no plan action executes.
      expect(driver.calls().map((call) => call.kind)).toEqual([
        "list_windows",
        "get_window_state",
        "list_tools",
      ]);
    } finally {
      clock.mockRestore();
    }
  });

  it("shows a blocked preview when no head candidates are available", async () => {
    const clock = vi.spyOn(Date, "now").mockReturnValue(1000);
    try {
      render(
        <Dashboard
          createStream={makeFactory()}
          headPointing={{ point: { x: 10, y: 20 }, candidates: [] }}
          now={() => "2026-06-22T12:00:00.000Z"}
          // The default resolver is now the full-surface LLM path (no client in
          // tests); inject the rule resolver so the no-candidate clarification is
          // produced deterministically.
          resolveIntent={ruleResolver}
          targetResolveDelayMs={0}
        />,
      );

      fireEvent.pointerDown(talkButton());
      await flush();
      act(() => latest().emitFinal("click there", 0.95, 100));
      clock.mockReturnValue(1400);
      fireEvent.pointerUp(talkButton());
      await flush();

      // The no-candidate clarification reason appears in the Referents/Plan
      // panels; no Approve button (the loop never produced an actionable plan).
      expect(
        (await screen.findAllByText("No attention-region candidates were available")).length,
      ).toBeGreaterThan(0);
      expect(screen.queryByRole("button", { name: "Approve" })).not.toBeInTheDocument();
    } finally {
      clock.mockRestore();
    }
  });
});
