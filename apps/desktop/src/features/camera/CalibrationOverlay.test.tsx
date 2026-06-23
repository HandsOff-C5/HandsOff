import type { CalibrationTarget } from "@handsoff/gesture";
import type { MultiMonitorCalibration } from "@handsoff/gesture";
import { multiMonitorTargets } from "@handsoff/gesture";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { CalibrationOverlay } from "./CalibrationOverlay";

// A single 1920×1080 display, 3×3 grid corner-to-corner — the per-display generalization of
// the old 9-point layout. With one display the multi-monitor fit collapses to a single affine
// that recovers the 1920/1080 scale.
const targets: CalibrationTarget[] = multiMonitorTargets(
  [{ id: "1", bounds: { x: 0, y: 0, w: 1920, h: 1080 } }],
  { cols: 3, rows: 3, margin: 0 },
);

// Raw pointing signals matching the screen = (1920·x, 1080·y) mapping, in grid order.
const gridRaws: Array<[number, number]> = targets.map((t) => {
  const [tx, ty] = t.target;
  return [tx / 1920, ty / 1080];
});

describe("CalibrationOverlay (per-display grid)", () => {
  it("shows 0-of-9 progress and drives the overlay to the first target on mount", () => {
    const onShowTarget = vi.fn();
    render(
      <CalibrationOverlay
        targets={targets}
        sampleRaw={() => [0, 0]}
        onShowTarget={onShowTarget}
        onComplete={vi.fn()}
      />,
    );
    expect(screen.getByText(/0\s*\/\s*9/)).toBeInTheDocument();
    expect(onShowTarget).toHaveBeenCalledWith(targets[0]);
  });

  it("advances the progress as each point is captured", () => {
    render(
      <CalibrationOverlay
        targets={targets}
        sampleRaw={() => [0, 0]}
        onShowTarget={vi.fn()}
        onComplete={vi.fn()}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /capture/i }));
    expect(screen.getByText(/1\s*\/\s*9/)).toBeInTheDocument();
  });

  it("fits a per-display affine and clears the overlay after all 9 captures", () => {
    const onComplete = vi.fn();
    const onShowTarget = vi.fn();
    let i = 0;
    render(
      <CalibrationOverlay
        targets={targets}
        sampleRaw={() => gridRaws[i++] ?? null}
        onShowTarget={onShowTarget}
        onComplete={onComplete}
      />,
    );
    for (let n = 0; n < 9; n++) fireEvent.click(screen.getByRole("button", { name: /capture/i }));

    expect(onComplete).toHaveBeenCalledOnce();
    const result = onComplete.mock.calls[0]?.[0] as MultiMonitorCalibration;
    expect(result.byDisplay["1"].transform.a).toBeCloseTo(1920, 3);
    expect(result.byDisplay["1"].transform.e).toBeCloseTo(1080, 3);
    expect(result.quality).toBe("good");
    // The overlay ring is cleared once the run completes.
    expect(onShowTarget).toHaveBeenLastCalledWith(null);
  });

  it("does not capture when no pointing signal is available", () => {
    render(
      <CalibrationOverlay
        targets={targets}
        sampleRaw={() => null}
        onShowTarget={vi.fn()}
        onComplete={vi.fn()}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /capture/i }));
    expect(screen.getByText(/0\s*\/\s*9/)).toBeInTheDocument();
  });
});
