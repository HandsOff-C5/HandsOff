import type { CuaAgentAction } from "@handsoff/contracts";

import type { OverlayVoiceState } from "./overlay-signal";

// The richer per-model signal the engine (hidden dashboard) streams to the
// supervisor HUD on the overlay window. Where OverlaySignal carries the single
// fused pointer, this carries EACH tracker separately — its own cursor, live
// confidence, frame rate, and what it's locked onto — plus the voice transcript
// and the agent's current action. It's what makes the overlay a full
// observability surface: every model visible, where it aims, how sure it is.

// Lamp state for a tracker row: live (strong fix), weak (fix but unsure), lost
// (no fix — e.g. the hand left the frame). Drives the row colour in the HUD.
export type ModelStatus = "live" | "weak" | "lost";

// At/above this fused confidence a tracker reads as a strong "live" lock.
export const LIVE_CONFIDENCE = 0.6;

export interface ModelTrack {
  // Normalized overlay-space [0,1] cursor (x,y), or null when this model has no fix.
  point: [number, number] | null;
  // This model's confidence [0,1] this frame.
  confidence: number;
  // Measured update rate (frames/sec); 0 when unknown.
  fps: number;
  // What it's currently locked onto, or null.
  lock: string | null;
}

export interface AgentState {
  // The CUA's current action in plain words, or null when idle.
  action: string | null;
  // Whether a mutating step is awaiting human approval.
  pendingApproval: boolean;
}

export interface SupervisorSnapshot {
  hand: ModelTrack;
  gaze: ModelTrack;
  voice: { state: OverlayVoiceState; transcript: string | null };
  agent: AgentState;
}

const IDLE_TRACK: ModelTrack = { point: null, confidence: 0, fps: 0, lock: null };

export const IDLE_SUPERVISOR_SNAPSHOT: SupervisorSnapshot = {
  hand: { ...IDLE_TRACK },
  gaze: { ...IDLE_TRACK },
  voice: { state: "idle", transcript: null },
  agent: { action: null, pendingApproval: false },
};

// Lamp for a tracker row (STRICT): no fix → lost (the row reddens); a fix at or
// above LIVE_CONFIDENCE → live; otherwise a fix but unsure → weak.
export function modelStatus(track: ModelTrack): ModelStatus {
  if (!track.point) return "lost";
  return track.confidence >= LIVE_CONFIDENCE ? "live" : "weak";
}

// Confidence [0,1] → a whole-percent label, clamped into [0,100]; non-finite → "—".
export function formatConfidencePct(confidence: number): string {
  if (!Number.isFinite(confidence)) return "—";
  const clamped = Math.min(1, Math.max(0, confidence));
  return `${Math.round(clamped * 100)}%`;
}

// Frame rate → a short label; no measurable rate (≤0 or non-finite) → "—".
export function formatFps(fps: number): string {
  if (!Number.isFinite(fps) || fps <= 0) return "—";
  return `${Math.round(fps)}fps`;
}

// Derive a frame rate from a window of frame timestamps (ms). Fewer than two
// samples, or a zero span (all identical), has no measurable rate → 0. Otherwise
// (n-1) intervals across the span, rounded.
export function fpsFromTimestamps(timestampsMs: readonly number[]): number {
  if (timestampsMs.length < 2) return 0;
  const first = timestampsMs[0];
  const last = timestampsMs[timestampsMs.length - 1];
  if (first === undefined || last === undefined) return 0;
  const spanSeconds = (last - first) / 1000;
  if (spanSeconds <= 0) return 0;
  return Math.round((timestampsMs.length - 1) / spanSeconds);
}

// The agent banner's plain-words line: the current action, or "Idle".
export function agentBannerText(agent: AgentState): string {
  return agent.action ? `Acting: ${agent.action}` : "Idle";
}

// Turn one AX-native CUA action into plain words for the agent banner, so the
// operator reads "click element #3" / 'type "hello"' instead of raw JSON. STRICT
// over the discriminated union so a new action kind is a compile error here.
export function describeCuaAgentAction(action: CuaAgentAction): string {
  switch (action.kind) {
    case "snapshot":
      return "look at the window";
    case "click":
      return `click element #${action.elementIndex}`;
    case "click_point":
      return `click at (${action.x}, ${action.y})`;
    case "type_text":
      return `type "${action.text}"`;
    case "set_value":
      return `set value to "${action.value}"`;
    case "press_key": {
      const chord = [...(action.modifiers ?? []), action.key].join("+");
      return `press ${chord}`;
    }
    case "hotkey":
      return `press ${action.keys.join("+")}`;
    case "scroll":
      return `scroll ${action.direction}`;
    case "launch_app":
      return `launch ${action.appName}`;
  }
}
