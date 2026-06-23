import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import {
  CAPTURE_HOTKEY_EVENT,
  useCaptureHotkey,
  type CaptureHotkeyListenEvent,
} from "./useCaptureHotkey";

describe("useCaptureHotkey", () => {
  it("starts head tracking and capture on a start phase, stops on stop", async () => {
    let handler: ((event: CaptureHotkeyListenEvent) => void) | null = null;
    const listen = vi.fn(
      async (_event: string, next: (event: CaptureHotkeyListenEvent) => void) => {
        handler = next;
        return vi.fn();
      },
    );
    const invoke = vi.fn(async () => undefined);
    const onStart = vi.fn();
    const onStop = vi.fn();

    const headPointer = { movementMode: "edge" as const, speed: 5, distanceToEdge: 0.12 };

    renderHook(() => useCaptureHotkey({ listen, invoke, headPointer, onStart, onStop }));
    await waitFor(() =>
      expect(listen).toHaveBeenCalledWith(CAPTURE_HOTKEY_EVENT, expect.any(Function)),
    );

    act(() => handler?.({ payload: { phase: "start" } }));
    await waitFor(() => expect(invoke).toHaveBeenCalledWith("head_track_start", { headPointer }));
    await waitFor(() => expect(onStart).toHaveBeenCalledTimes(1));

    act(() => handler?.({ payload: { phase: "stop" } }));
    expect(invoke).toHaveBeenCalledWith("head_track_stop");
    expect(onStop).toHaveBeenCalledTimes(1);
  });

  it("ignores payloads without a valid phase", async () => {
    let handler: ((event: CaptureHotkeyListenEvent) => void) | null = null;
    const listen = vi.fn(
      async (_event: string, next: (event: CaptureHotkeyListenEvent) => void) => {
        handler = next;
        return vi.fn();
      },
    );
    const invoke = vi.fn(async () => undefined);

    renderHook(() => useCaptureHotkey({ listen, invoke }));
    await waitFor(() => expect(handler).not.toBeNull());

    act(() => handler?.({ payload: { phase: "weird" } }));
    act(() => handler?.({ payload: null }));
    expect(invoke).not.toHaveBeenCalled();
  });

  it("does not start voice capture when head tracking fails to start", async () => {
    let handler: ((event: CaptureHotkeyListenEvent) => void) | null = null;
    const listen = vi.fn(
      async (_event: string, next: (event: CaptureHotkeyListenEvent) => void) => {
        handler = next;
        return vi.fn();
      },
    );
    const invoke = vi.fn(async (command: string) => {
      if (command === "head_track_start") throw new Error("camera denied");
      return undefined;
    });
    const onStart = vi.fn();
    const onStartError = vi.fn();

    renderHook(() => useCaptureHotkey({ listen, invoke, onStart, onStartError }));
    await waitFor(() => expect(handler).not.toBeNull());

    act(() => handler?.({ payload: { phase: "start" } }));

    await waitFor(() => expect(onStartError).toHaveBeenCalledWith("camera denied"));
    expect(onStart).not.toHaveBeenCalled();
  });
});
