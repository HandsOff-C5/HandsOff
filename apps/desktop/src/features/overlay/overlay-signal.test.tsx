import { describe, expect, it } from "vitest";

import {
  deriveVoiceState,
  normalizeOverlayPoint,
  overlayMarkerStyle,
  VOICE_STATE_LABEL,
} from "./overlay-signal";

describe("normalizeOverlayPoint", () => {
  const unit = { x: 0, y: 0, w: 1, h: 1 };

  it("passes a unit-box point through unmirrored", () => {
    expect(normalizeOverlayPoint([0.3, 0.6], unit, false)).toEqual([0.3, 0.6]);
  });

  it("mirrors x for the selfie-view signal", () => {
    expect(normalizeOverlayPoint([0.25, 0.6], unit, true)).toEqual([0.75, 0.6]);
  });

  it("normalizes against calibration bounds", () => {
    const bounds = { x: 100, y: 200, w: 400, h: 400 };
    expect(normalizeOverlayPoint([300, 400], bounds, false)).toEqual([0.5, 0.5]);
  });
});

describe("deriveVoiceState", () => {
  it("acting wins over everything while a plan runs", () => {
    expect(deriveVoiceState({ captureStatus: "capturing", hasIntent: true, running: true })).toBe(
      "acting",
    );
  });

  it("listening while the mic is open", () => {
    expect(deriveVoiceState({ captureStatus: "capturing", hasIntent: false, running: false })).toBe(
      "listening",
    );
    expect(
      deriveVoiceState({ captureStatus: "finalizing", hasIntent: false, running: false }),
    ).toBe("listening");
  });

  it("heard once an intent is resolved and the mic is closed", () => {
    expect(deriveVoiceState({ captureStatus: "idle", hasIntent: true, running: false })).toBe(
      "heard",
    );
  });

  it("idle otherwise", () => {
    expect(deriveVoiceState({ captureStatus: "idle", hasIntent: false, running: false })).toBe(
      "idle",
    );
  });
});

describe("overlayMarkerStyle", () => {
  it("maps a normalized point to CSS percentages", () => {
    const style = overlayMarkerStyle([0.25, 0.75], 1);
    expect(style.left).toBe("25%");
    expect(style.top).toBe("75%");
  });

  it("clamps out-of-range points into the visible box", () => {
    const style = overlayMarkerStyle([1.5, -0.2], 1);
    expect(style.left).toBe("100%");
    expect(style.top).toBe("0%");
  });

  it("brightens and widens the glow with confidence", () => {
    const unsure = overlayMarkerStyle([0.5, 0.5], 0);
    const confident = overlayMarkerStyle([0.5, 0.5], 1);
    expect(confident.opacity).toBeGreaterThan(unsure.opacity);
    // Higher confidence → larger blur radius in the box-shadow string.
    const blur = (s: string): number => Number(s.match(/0 0 (\d+(?:\.\d+)?)px/)?.[1] ?? 0);
    expect(blur(confident.boxShadow)).toBeGreaterThan(blur(unsure.boxShadow));
  });

  it("treats a non-finite confidence as unsure", () => {
    const style = overlayMarkerStyle([0.5, 0.5], Number.NaN);
    expect(style.opacity).toBe(0.35);
  });
});

describe("VOICE_STATE_LABEL", () => {
  it("labels every voice state", () => {
    expect(VOICE_STATE_LABEL.idle).toBe("Ready");
    expect(VOICE_STATE_LABEL.listening).toBe("Listening…");
    expect(VOICE_STATE_LABEL.heard).toBe("Heard you");
    expect(VOICE_STATE_LABEL.acting).toBe("Acting…");
  });
});
