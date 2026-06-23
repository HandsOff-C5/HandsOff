import type { HeadPointerConfig } from "@handsoff/contracts";
import { useEffect, useRef } from "react";

// The app process owns the global capture shortcuts (#95) and emits
// `hotkey://capture` phases. Command+Option+? is hold-to-capture
// (`start`/`stop`), and Control+Shift+Space is tap-to-toggle (`toggle`).

export const CAPTURE_HOTKEY_EVENT = "hotkey://capture";
type CaptureHotkeyPhase = "start" | "stop" | "toggle";

export type CaptureHotkeyListenEvent = { readonly payload: unknown };
export type CaptureHotkeyListen = (
  event: string,
  handler: (event: CaptureHotkeyListenEvent) => void,
) => Promise<() => void>;
export type CaptureHotkeyInvoke = (
  command: string,
  args?: Record<string, unknown>,
) => Promise<unknown>;

function phaseOf(payload: unknown): CaptureHotkeyPhase | null {
  if (typeof payload !== "object" || payload === null) return null;
  const phase = (payload as { phase?: unknown }).phase;
  return phase === "start" || phase === "stop" || phase === "toggle" ? phase : null;
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
    let captureRequested = false;
    let headTrackingStarted = false;

    const startCapture = async () => {
      if (captureRequested) return;
      captureRequested = true;
      const token = ++captureToken;
      try {
        const headPointer = latest.current.headPointer;
        await invoke?.("head_track_start", headPointer ? { headPointer } : undefined);
        if (!mounted || token !== captureToken || !captureRequested) {
          void invoke?.("head_track_stop");
          return;
        }
        headTrackingStarted = true;
        latest.current.onStart?.();
      } catch (error) {
        if (!mounted || token !== captureToken) return;
        captureRequested = false;
        headTrackingStarted = false;
        latest.current.onStartError?.(
          error instanceof Error ? error.message : "Could not start head tracking",
        );
      }
    };

    const stopCapture = () => {
      if (!captureRequested && !headTrackingStarted) return;
      captureToken += 1;
      captureRequested = false;
      const wasStarted = headTrackingStarted;
      headTrackingStarted = false;
      void invoke?.("head_track_stop");
      if (wasStarted) latest.current.onStop?.();
    };

    void listen(CAPTURE_HOTKEY_EVENT, ({ payload }) => {
      if (!mounted) return;
      const phase = phaseOf(payload);
      if (!phase) return;
      if (phase === "start") {
        void startCapture();
      } else if (phase === "stop") {
        stopCapture();
      } else if (captureRequested || headTrackingStarted) {
        stopCapture();
      } else {
        void startCapture();
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
