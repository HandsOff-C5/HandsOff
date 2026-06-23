import type { SurfaceBounds } from "@handsoff/contracts";
import type { CalibrationResult, Point } from "@handsoff/gesture";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { CalibrationOverlay } from "./CalibrationOverlay";

const bounds: SurfaceBounds = { x: 0, y: 0, w: 1920, h: 1080 };

// Raw pointing signals matching a known screen = (1920·x, 1080·y) mapping, in grid order
// (margin 0 → corners + center). One per capture; the fit should recover ~1920/1080.
const gridRaws: Point[] = [];
for (let r = 0; r < 3; r++) {
  for (let c = 0; c < 3; c++) gridRaws.push([c / 2, r / 2]);
}

describe("CalibrationOverlay (9-point)", () => {
  it("shows the first target and 0-of-9 progress", () => {
    render(
      <CalibrationOverlay
        bounds={bounds}
        margin={0}
        sampleRaw={() => [0, 0]}
        onComplete={vi.fn()}
      />,
    );
    expect(screen.getByText(/0\s*\/\s*9/)).toBeInTheDocument();
    expect(screen.getByTestId("calibration-target")).toBeInTheDocument();
  });

  it("advances the progress as each point is captured", () => {
    render(
      <CalibrationOverlay
        bounds={bounds}
        margin={0}
        sampleRaw={() => [0, 0]}
        onComplete={vi.fn()}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /capture/i }));
    expect(screen.getByText(/1\s*\/\s*9/)).toBeInTheDocument();
  });

  it("fits and reports a transform after all 9 points are captured", () => {
    const onComplete = vi.fn();
    let i = 0;
    const sampleRaw = () => gridRaws[i++] ?? null;
    render(
      <CalibrationOverlay
        bounds={bounds}
        margin={0}
        sampleRaw={sampleRaw}
        onComplete={onComplete}
      />,
    );
    for (let n = 0; n < 9; n++) fireEvent.click(screen.getByRole("button", { name: /capture/i }));

    expect(onComplete).toHaveBeenCalledOnce();
    const result = onComplete.mock.calls[0]?.[0] as CalibrationResult;
    expect(result.transform.a).toBeCloseTo(1920, 3);
    expect(result.transform.e).toBeCloseTo(1080, 3);
    expect(result.quality).toBe("good");
  });

  it("does not capture when no pointing signal is available", () => {
    const onComplete = vi.fn();
    render(
      <CalibrationOverlay
        bounds={bounds}
        margin={0}
        sampleRaw={() => null}
        onComplete={onComplete}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /capture/i }));
    expect(screen.getByText(/0\s*\/\s*9/)).toBeInTheDocument();
  });
});
