import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { useSharedWebcam, type GetStream } from "./useSharedWebcam";

function fakeStream(): { stream: MediaStream; stop: ReturnType<typeof vi.fn> } {
  const stop = vi.fn();
  const stream = { getTracks: () => [{ stop }] } as unknown as MediaStream;
  return { stream, stop };
}

describe("useSharedWebcam", () => {
  it("starts idle with no stream (no auto-start, for privacy)", () => {
    const getStream = vi.fn();
    const { result } = renderHook(() => useSharedWebcam(getStream as unknown as GetStream));
    expect(result.current.status).toBe("idle");
    expect(result.current.stream).toBeNull();
    expect(getStream).not.toHaveBeenCalled();
  });

  it("acquires the shared stream on start()", async () => {
    const { stream } = fakeStream();
    const getStream: GetStream = vi.fn().mockResolvedValue(stream);
    const { result } = renderHook(() => useSharedWebcam(getStream));

    act(() => result.current.start());

    await waitFor(() => expect(result.current.status).toBe("live"));
    expect(result.current.stream).toBe(stream);
  });

  it("reports an error when acquisition fails", async () => {
    const getStream: GetStream = vi.fn().mockRejectedValue(new Error("permission denied"));
    const { result } = renderHook(() => useSharedWebcam(getStream));

    act(() => result.current.start());

    await waitFor(() => expect(result.current.status).toBe("error"));
    expect(result.current.error).toMatch(/permission denied/);
    expect(result.current.stream).toBeNull();
  });

  it("stops the tracks and clears the stream on stop()", async () => {
    const { stream, stop } = fakeStream();
    const getStream: GetStream = vi.fn().mockResolvedValue(stream);
    const { result } = renderHook(() => useSharedWebcam(getStream));

    act(() => result.current.start());
    await waitFor(() => expect(result.current.status).toBe("live"));

    act(() => result.current.stop());

    expect(stop).toHaveBeenCalledTimes(1);
    expect(result.current.stream).toBeNull();
    expect(result.current.status).toBe("idle");
  });
});
