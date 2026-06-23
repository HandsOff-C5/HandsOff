import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import {
  HEAD_POINTING_EVENT,
  useHeadPointing,
  type HeadPointingListenEvent,
} from "./useHeadPointing";

describe("useHeadPointing", () => {
  it("subscribes to head events and records the latest candidates", async () => {
    let handler: ((event: HeadPointingListenEvent) => void) | null = null;
    const unlisten = vi.fn();
    const listen = vi.fn(async (_event: string, next: (event: HeadPointingListenEvent) => void) => {
      handler = next;
      return unlisten;
    });
    const invoke = vi.fn(async () => undefined);

    const { result, unmount } = renderHook(() => useHeadPointing({ listen, invoke }));

    await waitFor(() =>
      expect(listen).toHaveBeenCalledWith(HEAD_POINTING_EVENT, expect.any(Function)),
    );
    // Head tracking is started by the capture hotkey, not on mount (#95).
    expect(invoke).not.toHaveBeenCalledWith("head_track_start");

    act(() => {
      handler?.({
        payload: {
          kind: "point",
          x: 10,
          y: 20,
          yaw: null,
          pitch: null,
          confidence: 0.9,
          ts: 1,
        },
      });
    });
    expect(result.current).toMatchObject({ status: "tracking", point: { x: 10, y: 20 } });

    const candidate = {
      surface: {
        id: "surface-1",
        title: "Codex",
        app: "Codex",
        pid: 42,
        windowId: 7,
        availability: "available" as const,
        accessStatus: "accessible" as const,
      },
      score: 1,
      distance: 0,
    };
    act(() => {
      handler?.({
        payload: {
          kind: "candidates",
          point: { x: 10, y: 20 },
          candidates: [candidate],
          ts: 2,
        },
      });
    });

    expect(result.current).toMatchObject({
      status: "idle",
      point: { x: 10, y: 20 },
      candidates: [candidate],
    });

    unmount();
    expect(unlisten).toHaveBeenCalledTimes(1);
  });

  it("surfaces invalid event payloads", async () => {
    let handler: ((event: HeadPointingListenEvent) => void) | null = null;
    const listen = vi.fn(async (_event: string, next: (event: HeadPointingListenEvent) => void) => {
      handler = next;
      return vi.fn();
    });

    const { result } = renderHook(() => useHeadPointing({ listen }));
    await waitFor(() => expect(handler).not.toBeNull());

    act(() => handler?.({ payload: { kind: "point", confidence: 2 } }));

    expect(result.current).toMatchObject({
      status: "error",
      error: "Invalid head pointing event",
    });
  });
});
