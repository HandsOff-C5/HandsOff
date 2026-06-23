import { invoke } from "@tauri-apps/api/core";
import { useCallback } from "react";

// Frontend type for the display layout the Rust `list_displays` / `gesture_overlay_start`
// commands return: CoreGraphics global coordinates (top-left origin; secondary displays may
// be negative), mirroring the sidecar's authoritative layout.
export interface DisplayInfo {
  id: string;
  isMain: boolean;
  x: number;
  y: number;
  width: number;
  height: number;
}

// Imperative handle over the gesture-overlay sidecar. The cursor commands are fire-and-
// forget: a stray frame after stop, or a momentary sidecar hiccup, must never throw into the
// per-frame detection loop. `start` is the one call whose result (the display layout) the
// caller needs, so its errors propagate.
export interface GestureOverlay {
  start: () => Promise<DisplayInfo[]>;
  stop: () => Promise<void>;
  move: (cursorId: string, x: number, y: number) => void;
  target: (x: number, y: number) => void;
  untarget: () => void;
  clear: (cursorId?: string) => void;
}

const swallow = (error: unknown, context: string) => {
  // Expected when commands land after a stop or before a start — the cursor is best-effort.
  console.debug(`[handsoff gesture-overlay] ${context}`, error);
};

export function useGestureOverlay(): GestureOverlay {
  const start = useCallback(async () => {
    const displays = await invoke<DisplayInfo[]>("gesture_overlay_start");
    return displays;
  }, []);

  const stop = useCallback(async () => {
    await invoke("gesture_overlay_stop").catch((error: unknown) => swallow(error, "stop"));
  }, []);

  const move = useCallback((cursorId: string, x: number, y: number) => {
    void invoke("gesture_overlay_move", { cursorId, x, y }).catch((error: unknown) =>
      swallow(error, "move"),
    );
  }, []);

  const target = useCallback((x: number, y: number) => {
    void invoke("gesture_overlay_target", { x, y }).catch((error: unknown) =>
      swallow(error, "target"),
    );
  }, []);

  const untarget = useCallback(() => {
    void invoke("gesture_overlay_untarget").catch((error: unknown) => swallow(error, "untarget"));
  }, []);

  const clear = useCallback((cursorId?: string) => {
    void invoke("gesture_overlay_clear", { cursorId: cursorId ?? null }).catch((error: unknown) =>
      swallow(error, "clear"),
    );
  }, []);

  return { start, stop, move, target, untarget, clear };
}
