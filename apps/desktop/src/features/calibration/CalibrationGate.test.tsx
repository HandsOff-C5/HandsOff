import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { CalibrationGate } from "./CalibrationGate";
import type { CalibrationView } from "./calibration-flow";

function view(overrides: Partial<CalibrationView> = {}): CalibrationView {
  return {
    active: true,
    phase: "hand",
    step: 1,
    totalSteps: 2,
    targets: Array.from({ length: 9 }, (_, i) => [
      0.1 + (i % 3) * 0.4,
      0.1 + Math.floor(i / 3) * 0.4,
    ]),
    currentIndex: 3,
    dwellProgress: 0.5,
    quality: null,
    ...overrides,
  };
}

describe("CalibrationGate", () => {
  it("titles the hand phase and renders all nine dots", () => {
    render(<CalibrationGate view={view()} cursor={null} onSkip={() => {}} />);
    expect(screen.getByText(/step 1 of 2/i)).toBeInTheDocument();
    expect(screen.getByText(/hand/i)).toBeInTheDocument();
    expect(screen.getAllByTestId("calib-dot")).toHaveLength(9);
  });

  it("titles the eyes phase", () => {
    render(
      <CalibrationGate view={view({ phase: "gaze", step: 2 })} cursor={null} onSkip={() => {}} />,
    );
    expect(screen.getByText(/step 2 of 2/i)).toBeInTheDocument();
    expect(screen.getByText(/eyes/i)).toBeInTheDocument();
  });

  it("marks the glowing dot active, the earlier dots captured, and shows dwell fill", () => {
    render(
      <CalibrationGate
        view={view({ currentIndex: 3, dwellProgress: 0.5 })}
        cursor={null}
        onSkip={() => {}}
      />,
    );
    const dots = screen.getAllByTestId("calib-dot");
    expect(dots[3]).toHaveAttribute("data-active", "true");
    expect(dots[0]).toHaveAttribute("data-captured", "true");
    expect(dots[5]).toHaveAttribute("data-captured", "false");
    expect(dots[3]).toHaveAttribute("data-progress", "0.5");
  });

  it("renders the live cursor when one is provided", () => {
    render(<CalibrationGate view={view()} cursor={[0.25, 0.75]} onSkip={() => {}} />);
    const cursor = screen.getByTestId("calib-cursor");
    expect(cursor.style.left).toBe("25%");
    expect(cursor.style.top).toBe("75%");
  });

  it("routes the skip control", () => {
    const onSkip = vi.fn();
    render(<CalibrationGate view={view()} cursor={null} onSkip={onSkip} />);
    fireEvent.click(screen.getByRole("button", { name: /skip/i }));
    expect(onSkip).toHaveBeenCalledTimes(1);
  });
});
