import { cuaWindowSchema, type CuaWindow } from "@handsoff/contracts";

import type { CuaInvoke } from "../tauri-driver";

import type { CuaAgentTarget } from "./ax-env";
import type { CuaReferent } from "./escalation";

// A usable target window: actually available, accessible, and not the cua-driver's
// own window (which would let the agent drive the driver). Mirrors the same gate
// the deterministic CuaDriver uses so the agent and the planned path agree.
function isUsableWindow(window: CuaWindow): boolean {
  return (
    window.availability === "available" &&
    window.accessStatus === "accessible" &&
    !window.app.toLowerCase().includes("cua driver")
  );
}

// A referent app name worth matching on — a blank or the generic "Current app"
// placeholder means "no specific app", so we fall back to the focused window.
function namedApp(referent: CuaReferent | undefined): string | null {
  const app = referent?.app.trim();
  return app && app.toLowerCase() !== "current app" ? app.toLowerCase() : null;
}

function toTarget(window: CuaWindow | undefined): CuaAgentTarget | null {
  if (!window || window.pid === undefined || window.windowId === undefined) return null;
  return { pid: window.pid, windowId: window.windowId };
}

// Resolve the pointed-at referent to the concrete window the agent will operate
// within. Pure + total over the window list so it's unit-tested without Tauri.
//
// When the referent names an app, we only ever ground in a window of THAT app
// (preferring a title match) — never a random fallback, since acting in the
// wrong window is worse than not acting. With no named app we take the focused
// usable window, then the first usable one. Returns null when nothing grounds.
export function resolveReferentTarget(
  referent: CuaReferent | undefined,
  windows: readonly CuaWindow[],
): CuaAgentTarget | null {
  const usable = windows.filter(isUsableWindow);
  const app = namedApp(referent);

  if (app) {
    const appWindows = usable.filter((window) => window.app.toLowerCase() === app);
    if (appWindows.length === 0) return null;
    const title = referent?.title?.trim().toLowerCase();
    const titleMatch = title
      ? appWindows.find((window) => window.title.toLowerCase().includes(title))
      : undefined;
    const focused = appWindows.find((window) => window.focused);
    return toTarget(titleMatch ?? focused ?? appWindows[0]);
  }

  return toTarget(usable.find((window) => window.focused) ?? usable[0]);
}

// List the live windows via the driver, then resolve the referent against them.
// A driver failure yields null (the escalator treats that as "no window") rather
// than throwing, so a flaky list never crashes the loop.
export async function resolveTargetFromReferent(
  invoke: CuaInvoke,
  referent: CuaReferent | undefined,
): Promise<CuaAgentTarget | null> {
  try {
    const raw = await invoke<unknown>("cua_list_windows");
    const parsed = cuaWindowSchema.array().safeParse(raw);
    if (!parsed.success) return null;
    return resolveReferentTarget(referent, parsed.data);
  } catch {
    return null;
  }
}
