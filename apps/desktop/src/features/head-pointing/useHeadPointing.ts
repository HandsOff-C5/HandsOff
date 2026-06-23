import {
  safeParseHeadPointingAppEvent,
  type AttentionRegionCandidate,
  type HeadPoint,
} from "@handsoff/contracts";
import { useEffect, useState } from "react";

export const HEAD_POINTING_EVENT = "stt://head";

export type HeadPointingListenEvent = { readonly payload: unknown };
export type HeadPointingListen = (
  event: string,
  handler: (event: HeadPointingListenEvent) => void,
) => Promise<() => void>;
export type HeadPointingInvoke = (command: string) => Promise<unknown>;

export interface HeadPointingSnapshot {
  readonly point: HeadPoint | null;
  readonly candidates: readonly AttentionRegionCandidate[];
}

export interface HeadPointingState extends HeadPointingSnapshot {
  readonly status: "idle" | "tracking" | "error";
  readonly error: string | null;
}

export function useHeadPointing(options?: {
  readonly listen?: HeadPointingListen;
  readonly invoke?: HeadPointingInvoke;
}): HeadPointingState {
  const [state, setState] = useState<HeadPointingState>({
    status: "idle",
    point: null,
    candidates: [],
    error: null,
  });

  useEffect(() => {
    if (!options?.listen) return;

    let mounted = true;
    let unlisten: (() => void) | null = null;

    void options
      .listen(HEAD_POINTING_EVENT, ({ payload }) => {
        if (!mounted) return;
        const parsed = safeParseHeadPointingAppEvent(payload);
        if (!parsed.success) {
          setState((prev) => ({ ...prev, status: "error", error: "Invalid head pointing event" }));
          return;
        }

        const event = parsed.data;
        if (event.kind === "start") {
          setState((prev) => ({ ...prev, status: "tracking", error: null }));
        } else if (event.kind === "point") {
          setState((prev) => ({
            ...prev,
            status: "tracking",
            point: { x: event.x, y: event.y },
            error: null,
          }));
        } else if (event.kind === "stop") {
          setState((prev) => ({ ...prev, status: "idle", error: null }));
        } else if (event.kind === "candidates") {
          setState((prev) => ({
            ...prev,
            status: "idle",
            point: event.point,
            candidates: event.candidates,
            error: null,
          }));
        } else {
          setState((prev) => ({ ...prev, status: "error", error: event.message }));
        }
      })
      .then((nextUnlisten) => {
        if (!mounted) {
          nextUnlisten();
          return;
        }
        unlisten = nextUnlisten;
      })
      .catch((caught) => {
        if (!mounted) return;
        setState((prev) => ({
          ...prev,
          status: "error",
          error: caught instanceof Error ? caught.message : String(caught),
        }));
      });

    return () => {
      mounted = false;
      unlisten?.();
    };
    // Head tracking is started/stopped by the capture hotkey (see useCaptureHotkey),
    // not on mount — this hook only renders the live head-pointing state.
  }, [options?.listen]);

  return state;
}
