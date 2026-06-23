import type { FinalTranscript, PointingEvidence } from "@handsoff/contracts";
import { createFakeCuaDriver } from "@handsoff/cua";
import { fakeCuaWindowState } from "@handsoff/testkit";
import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { useVoiceCuaController } from "./useVoiceCuaController";

const transcript: FinalTranscript = {
  kind: "final",
  text: "click there",
  confidence: 0.95,
  latencyMs: 100,
  receivedAt: 1,
};

// A locked gesture referent resolved to a surface distinct from the fake driver's
// active-window surface ("surface-1"), so the assertion proves the intent bound to
// what the user POINTED at — not the active window the cursor path would pick.
const gestureEvidence: PointingEvidence = {
  source: "gesture",
  confidence: 0.9,
  strategy: "wrist-ray-calibrated:good",
  surface: {
    id: "gesture-target",
    title: "Pointed window",
    app: "Demo",
    availability: "available",
    accessStatus: "accessible",
  },
};

describe("useVoiceCuaController gesture wiring (#35)", () => {
  it("binds the intent to the pointed gesture surface, not the active window", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState() });
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        targetResolveDelayMs: 0,
        getGestureEvidence: () => gestureEvidence,
      }),
    );

    act(() => result.current.handleFinalTranscript(transcript));

    await waitFor(() => expect(result.current.intent?.status).toBe("ready"));
    expect(result.current.intent).toMatchObject({
      status: "ready",
      referent: { id: "gesture-target" },
    });
    // The gesture path must NOT fall back to the active-window cursor probe.
    expect(driver.calls().some((c) => c.kind === "get_window_state")).toBe(false);
  });

  it("falls back to the active-window cursor path when no gesture evidence is locked", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState() });
    const { result } = renderHook(() =>
      useVoiceCuaController({
        driver,
        targetResolveDelayMs: 0,
        getGestureEvidence: () => null,
      }),
    );

    act(() => result.current.handleFinalTranscript(transcript));

    await waitFor(() => expect(result.current.intent?.status).toBe("ready"));
    expect(result.current.intent).toMatchObject({
      status: "ready",
      referent: { id: "surface-1" },
    });
    expect(driver.calls().some((c) => c.kind === "get_window_state")).toBe(true);
  });
});
