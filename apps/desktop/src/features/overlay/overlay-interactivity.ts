// Pure decision for whether the transparent overlay window should swallow clicks.
//
// The overlay is click-through by default (set_ignore_cursor_events(true)) so the
// real desktop stays usable beneath the HUD. It must flip interactive whenever an
// on-overlay control actually needs to receive clicks. Today that's a pending CUA
// approval chip OR the first-run permission onboarding modal — composed so neither
// source clobbers the other (a single OR, one source of truth).

export interface OverlayInteractivityInput {
  // CUA approvals awaiting a decision on the overlay chip.
  readonly pendingApprovals: number;
  // The first-run permission onboarding modal is showing.
  readonly showOnboarding: boolean;
  // The calibration gate is active (its Skip control needs clicks too). Optional
  // so existing callers/tests need no change.
  readonly calibrationActive?: boolean;
}

export function overlayShouldBeInteractive(input: OverlayInteractivityInput): boolean {
  return input.pendingApprovals > 0 || input.showOnboarding;
}
