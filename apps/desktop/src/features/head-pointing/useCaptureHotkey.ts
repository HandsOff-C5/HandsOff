import type { HeadPointerConfig } from "@handsoff/contracts";
import { useEffect, useRef } from "react";

// The app process owns the Command + Option + / global shortcut (#95) and emits
// `hotkey://capture` {phase: "start"|"stop"} as the user holds/releases. This
// hook turns those into head-tracking start/stop, so capture is driven by the
// hotkey rather than on dashboard mount.

export const CAPTURE_HOTKEY_EVENT = "hotkey://capture";

export type CaptureHotkeyListenEvent = { readonly payload: unknown };
export type CaptureHotkeyListen = (
  event: string,
  handler: (event: CaptureHotkeyListenEvent) => void,
) => Promise<() => void>;
export type CaptureHotkeyInvoke = (
  command: string,
  args?: Record<string, unknown>,
) => Promise<unknown>;

function phaseOf(payload: unknown): "start" | "stop" | null {
  if (typeof payload !== "object" || payload === null) return null;
  const phase = (payload as { phase?: unknown }).phase;
  return phase === "start" || phase === "stop" ? phase : null;
}

export function useCaptureHotkey(options?: {
  readonly listen?: CaptureHotkeyListen;
  readonly invoke?: CaptureHotkeyInvoke;
  readonly headPointer?: HeadPointerConfig;
  readonly onStart?: () => void;
  readonly onStop?: () => void;
  readonly onStartError?: (message: string) => void;
}): void {
  const listen = options?.listen;
  const invoke = options?.invoke;
  const latest = useRef({
    headPointer: options?.headPointer,
    onStart: options?.onStart,
    onStop: options?.onStop,
    onStartError: options?.onStartError,
  });
  latest.current = {
    headPointer: options?.headPointer,
    onStart: options?.onStart,
    onStop: options?.onStop,
    onStartError: options?.onStartError,
  };

  useEffect(() => {
    if (!listen) return;

    let mounted = true;
    let unlisten: (() => void) | null = null;
    let captureToken = 0;
    let headTrackingStarted = false;

    const startCapture = async () => {
      const token = ++captureToken;
      try {
        const headPointer = latest.current.headPointer;
        await invoke?.("head_track_start", headPointer ? { headPointer } : undefined);
        if (!mounted || token !== captureToken) {
          void invoke?.("head_track_stop");
          return;
        }
        headTrackingStarted = true;
        latest.current.onStart?.();
      } catch (error) {
        if (!mounted || token !== captureToken) return;
        latest.current.onStartError?.(
          error instanceof Error ? error.message : "Could not start head tracking",
        );
      }
    };

    const stopCapture = () => {
      captureToken += 1;
      const wasStarted = headTrackingStarted;
      headTrackingStarted = false;
      void invoke?.("head_track_stop");
      if (wasStarted) latest.current.onStop?.();
    };

    void listen(CAPTURE_HOTKEY_EVENT, ({ payload }) => {
      if (!mounted) return;
      const phase = phaseOf(payload);
      if (phase === "start") {
        void startCapture();
      } else if (phase === "stop") {
        stopCapture();
      }
    }).then((next) => {
      if (!mounted) {
        next();
        return;
      }
      unlisten = next;
    });

    return () => {
      mounted = false;
      captureToken += 1;
      unlisten?.();
    };
  }, [listen, invoke]);
}
