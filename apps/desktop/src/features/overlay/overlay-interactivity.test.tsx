import { describe, expect, it } from "vitest";

import { overlayShouldBeInteractive } from "./overlay-interactivity";

// The overlay is click-through by default so the desktop stays usable; it must
// become interactive whenever an on-overlay control needs clicks. The sources
// must COMPOSE — neither clobbers the other.
describe("overlayShouldBeInteractive", () => {
  it("stays click-through when nothing on the overlay needs clicks", () => {
    expect(overlayShouldBeInteractive({ pendingApprovals: 0, showOnboarding: false })).toBe(false);
  });

  it("becomes interactive while a CUA approval is pending", () => {
    expect(overlayShouldBeInteractive({ pendingApprovals: 1, showOnboarding: false })).toBe(true);
  });

  it("becomes interactive while the onboarding modal is shown", () => {
    expect(overlayShouldBeInteractive({ pendingApprovals: 0, showOnboarding: true })).toBe(true);
  });

  it("stays interactive when both sources want it (no clobber)", () => {
    expect(overlayShouldBeInteractive({ pendingApprovals: 2, showOnboarding: true })).toBe(true);
  });

  it("becomes interactive while the calibration gate is active (its Skip needs clicks)", () => {
    expect(
      overlayShouldBeInteractive({
        pendingApprovals: 0,
        showOnboarding: false,
        calibrationActive: true,
      }),
    ).toBe(true);
  });
});
