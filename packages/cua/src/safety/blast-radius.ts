import type { ComputerAction, RiskLevel } from "@handsoff/contracts";

// The blast-radius floor for a single computer-use action. This is the
// consequence-agnostic lower bound: it classifies by what the action *can* do,
// not by the specific UI it lands on. Consumers pair it with the existing
// `requiresApproval(RiskLevel)` policy (intent/risk.ts) — read_only/reversible
// auto-run, mutating/destructive escalate to approval — and may raise (never
// lower) the tier when the brain knows the target is dangerous (e.g. a "Delete"
// button → destructive). The CUA loop and the approval UI both rely on this.
//
// No action classifies as `destructive` from shape alone: irreversibility is a
// property of the target, which only the semantic layer can see.
export function classifyComputerAction(action: ComputerAction): RiskLevel {
  switch (action.action) {
    // Observe-only: see the screen, move the cursor, or pause. No state change.
    case "screenshot":
    case "cursor_position":
    case "mouse_move":
    case "zoom":
    case "wait":
      return "read_only";
    // Scrolling changes what's visible, not application state — trivially undone.
    case "scroll":
      return "reversible";
    // Clicks, drags, typing, and key presses commit input that cannot be assumed
    // reversible, so they escalate to approval by default.
    case "left_click":
    case "right_click":
    case "middle_click":
    case "double_click":
    case "triple_click":
    case "left_click_drag":
    case "left_mouse_down":
    case "left_mouse_up":
    case "type":
    case "key":
    case "hold_key":
      return "mutating";
  }
}
