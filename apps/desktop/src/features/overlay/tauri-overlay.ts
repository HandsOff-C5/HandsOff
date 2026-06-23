import { emit, listen } from "@tauri-apps/api/event";

import { hasTauriBackend } from "../../lib/tauri";
import type { OverlayListen } from "./PointingOverlay";
import {
  OVERLAY_POINTER_EVENT,
  OVERLAY_VOICE_EVENT,
  type OverlayPointerUpdate,
  type OverlayVoiceState,
} from "./overlay-signal";

// Thin Tauri I/O shell for the overlay signal. The main (dashboard) window emits; the
// overlay window listens. No-ops outside Tauri (browser/tests) so callers stay unguarded.

export function emitOverlayPointer(update: OverlayPointerUpdate): void {
  if (hasTauriBackend()) void emit(OVERLAY_POINTER_EVENT, update);
}

export function emitOverlayVoice(state: OverlayVoiceState): void {
  if (hasTauriBackend()) void emit(OVERLAY_VOICE_EVENT, state);
}

// Backs PointingOverlay's `listen` prop in the overlay window: subscribes to both the
// pointer and voice events and returns one unsubscribe. Tauri `listen` is async, so we
// track the unlisten fns as they resolve and cancel any that arrive after teardown.
export const tauriOverlayListen: OverlayListen = (onPointer, onVoice) => {
  const unlisteners: Array<() => void> = [];
  let cancelled = false;
  const track = (pending: Promise<() => void>): void => {
    void pending.then((unlisten) => {
      if (cancelled) unlisten();
      else unlisteners.push(unlisten);
    });
  };
  track(listen<OverlayPointerUpdate>(OVERLAY_POINTER_EVENT, (event) => onPointer(event.payload)));
  track(listen<OverlayVoiceState>(OVERLAY_VOICE_EVENT, (event) => onVoice(event.payload)));
  return () => {
    cancelled = true;
    unlisteners.forEach((unlisten) => unlisten());
  };
};
