import { createEyeCalibration, type EyeCalibrationView } from "@handsoff/gesture";
import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { EyeCalibrationStage, type EyeCalibrationStageProps } from "./EyeCalibrationStage";

const baseView = (): EyeCalibrationView =>
  createEyeCalibration({
    monitors: [
      { x: 0, y: 0, w: 1000, h: 800 },
      { x: 1000, y: 0, w: 500, h: 500 },
    ],
  }).view();

const props = (over: Partial<EyeCalibrationStageProps> = {}): EyeCalibrationStageProps => ({
  status: "ready",
  error: null,
  stream: null,
  points: [{ x: 0.5, y: 0.5, kind: "iris" }],
  features: { irisXL: 0.5, irisYL: 0.5, irisXR: 0.5, irisYR: 0.5, eyeAspect: 0.3 },
  confidence: 0.82,
  view: baseView(),
  dotUnion: [0.12, 0.12],
  captureProgress: 0.5,
  outcome: null,
  onRedo: vi.fn(),
  ...over,
});

describe("EyeCalibrationStage", () => {
  it("shows the current dot, the live confidence, and the camera mirror with iris points", () => {
    render(<EyeCalibrationStage {...props()} />);
    expect(screen.getByTestId("eyecal-dot")).toBeInTheDocument();
    expect(screen.getByTestId("eyecal-mirror")).toBeInTheDocument();
    expect(screen.getByTestId("eyecal-point-iris")).toBeInTheDocument();
    expect(screen.getByTestId("eyecal-confidence")).toHaveTextContent("82%");
    expect(screen.getByTestId("eyecal-hud")).toHaveTextContent(/Screen 1 of 2/);
    expect(screen.getByTestId("eyecal-hud")).toHaveTextContent(/dot 1\/9/);
  });

  it("renders a camera-denied notice instead of the stage", () => {
    render(<EyeCalibrationStage {...props({ status: "denied", error: "NotAllowedError" })} />);
    expect(screen.getByTestId("eyecal-denied")).toBeInTheDocument();
    expect(screen.queryByTestId("eyecal-dot")).not.toBeInTheDocument();
    expect(screen.getByText(/NotAllowedError/)).toBeInTheDocument();
  });

  it("shows per-monitor results and a redo button when calibration is done", () => {
    const cal = createEyeCalibration({ monitors: [{ x: 0, y: 0, w: 1000, h: 800 }] });
    const fv = (i: number) => [
      (i % 3) * 0.4 + 0.1,
      Math.floor(i / 3) * 0.4 + 0.1,
      ((i * 7) % 9) / 10 + 0.05,
      ((i * 5 + 2) % 9) / 10 + 0.05,
    ];
    for (let i = 0; i < 9; i++) cal.capture(fv(i));
    render(
      <EyeCalibrationStage
        {...props({ view: cal.view(), dotUnion: null, outcome: cal.outcome() })}
      />,
    );
    expect(screen.getByText(/Calibration complete/)).toBeInTheDocument();
    expect(screen.getByText(/Screen 1:/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Calibrate again/ })).toBeInTheDocument();
    expect(screen.queryByTestId("eyecal-dot")).not.toBeInTheDocument();
  });
});
