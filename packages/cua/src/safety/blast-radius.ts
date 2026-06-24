import type { CuaAgentAction, RiskLevel } from "@handsoff/contracts";

// The blast-radius floor for a single CUA agent action. This is the
// consequence-agnostic lower bound: it classifies by what the action *can* do,
// not by the specific UI it lands on. Consumers pair it with the existing
// `requiresApproval(RiskLevel)` policy (intent/risk.ts) — read_only/reversible
// auto-run, mutating/destructive escalate to approval — and may raise (never
// lower) the tier when the brain knows the target is dangerous (e.g. a "Delete"
// button → destructive). The CUA loop and the approval UI both rely on this.
//
// No action classifies as `destructive` from shape alone: irreversibility is a
// property of the target, which only the semantic layer can see.
export function classifyCuaAgentAction(action: CuaAgentAction): RiskLevel {
  switch (action.kind) {
    // Observe-only: re-read the window's AX tree + screenshot. No state change.
    case "snapshot":
      return "read_only";
    // Scrolling changes what's visible, not application state — trivially undone.
    case "scroll":
      return "reversible";
    // Clicks, typing, value-sets, key presses, chords, and launches commit input
    // that cannot be assumed reversible, so they escalate to approval by default.
    case "click":
    case "click_point":
    case "type_text":
    case "set_value":
    case "press_key":
    case "hotkey":
    case "launch_app":
      return "mutating";
  }
}
