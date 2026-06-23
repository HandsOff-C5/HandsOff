import type { PointingEvidence } from "@handsoff/contracts";
import { emit, listen } from "@tauri-apps/api/event";

import { hasTauriBackend } from "../../lib/tauri";
import type { OverlayListen } from "./PointingOverlay";
import {
  OVERLAY_FUSION_EVENT,
  OVERLAY_POINTER_EVENT,
  OVERLAY_VOICE_EVENT,
  type OverlayPointerUpdate,
  type OverlayVoiceState,
} from "./overlay-signal";
import type { FusionListen } from "./useFusionSignal";

// Thin Tauri I/O shell for the overlay signal. The main (dashboard) window emits; the
// overlay window listens. No-ops outside Tauri (browser/tests) so callers stay unguarded.

export function emitOverlayPointer(update: OverlayPointerUpdate): void {
  if (hasTauriBackend()) void emit(OVERLAY_POINTER_EVENT, update);
}

export function emitOverlayVoice(state: OverlayVoiceState): void {
  if (hasTauriBackend()) void emit(OVERLAY_VOICE_EVENT, state);
}

export function emitOverlayFusion(evidence: PointingEvidence[]): void {
  if (hasTauriBackend()) void emit(OVERLAY_FUSION_EVENT, evidence);
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

// Backs FusionHud's `listen` prop in the overlay window: subscribes to the
// per-frame evidence event and returns one unsubscribe (same async-track pattern).
export const tauriFusionListen: FusionListen = (onEvidence) => {
  let cancelled = false;
  let unlisten: (() => void) | undefined;
  void listen<PointingEvidence[]>(OVERLAY_FUSION_EVENT, (event) => onEvidence(event.payload)).then(
    (fn) => {
      if (cancelled) fn();
      else unlisten = fn;
    },
  );
  return () => {
    cancelled = true;
    unlisten?.();
  };
};
