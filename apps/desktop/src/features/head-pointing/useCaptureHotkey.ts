import { useEffect } from "react";

// The app process owns the Right Option + ? CGEventTap (#95) and emits
// `hotkey://capture` {phase: "start"|"stop"} as the user holds/releases. This hook
// turns those into head-tracking start/stop, so capture is driven by the hotkey
// rather than on dashboard mount.

export const CAPTURE_HOTKEY_EVENT = "hotkey://capture";

export type CaptureHotkeyListenEvent = { readonly payload: unknown };
export type CaptureHotkeyListen = (
  event: string,
  handler: (event: CaptureHotkeyListenEvent) => void,
) => Promise<() => void>;
export type CaptureHotkeyInvoke = (command: string) => Promise<unknown>;

function phaseOf(payload: unknown): "start" | "stop" | null {
  if (typeof payload !== "object" || payload === null) return null;
  const phase = (payload as { phase?: unknown }).phase;
  return phase === "start" || phase === "stop" ? phase : null;
}

export function useCaptureHotkey(options?: {
  readonly listen?: CaptureHotkeyListen;
  readonly invoke?: CaptureHotkeyInvoke;
  readonly onStart?: () => void;
  readonly onStop?: () => void;
}): void {
  const listen = options?.listen;
  const invoke = options?.invoke;
  const onStart = options?.onStart;
  const onStop = options?.onStop;

  useEffect(() => {
    if (!listen) return;

    let mounted = true;
    let unlisten: (() => void) | null = null;

    void listen(CAPTURE_HOTKEY_EVENT, ({ payload }) => {
      if (!mounted) return;
      const phase = phaseOf(payload);
      if (phase === "start") {
        void invoke?.("head_track_start");
        onStart?.();
      } else if (phase === "stop") {
        void invoke?.("head_track_stop");
        onStop?.();
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
      unlisten?.();
    };
  }, [listen, invoke, onStart, onStop]);
}
