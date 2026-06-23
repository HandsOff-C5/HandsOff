import type { PointingEvidence, SurfaceSnapshot } from "@handsoff/contracts";
import { act, renderHook } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { useFusionSignal, type FusionListen } from "./useFusionSignal";

const cursor: SurfaceSnapshot = {
  id: "win:cursor",
  app: "Cursor",
  title: "editor",
  availability: "available",
  accessStatus: "accessible",
};
const v = (source: PointingEvidence["source"], confidence: number): PointingEvidence => ({
  source,
  confidence,
  strategy: source,
  surface: cursor,
});

describe("useFusionSignal", () => {
  it("returns null before any evidence arrives", () => {
    const { result } = renderHook(() => useFusionSignal(() => () => {}));
    expect(result.current).toBeNull();
  });

  it("fuses the latest evidence snapshot into an EvidenceFusion", () => {
    let push: (evidence: PointingEvidence[]) => void = () => {};
    const listen: FusionListen = (cb) => {
      push = cb;
      return () => {};
    };
    const { result } = renderHook(() => useFusionSignal(listen));

    act(() => push([v("gesture", 0.9), v("gaze", 0.6)]));

    expect(result.current?.decision).toBe("act");
    expect(result.current?.fusedConfidence).toBeCloseTo(0.96);
  });

  it("unsubscribes on unmount", () => {
    const unlisten = vi.fn();
    const listen: FusionListen = () => unlisten;
    const { unmount } = renderHook(() => useFusionSignal(listen));
    unmount();
    expect(unlisten).toHaveBeenCalledTimes(1);
  });

  it("returns null when no listener is provided", () => {
    const { result } = renderHook(() => useFusionSignal());
    expect(result.current).toBeNull();
  });
});
