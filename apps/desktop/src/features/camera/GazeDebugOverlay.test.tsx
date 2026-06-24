import type { GazeOverlayPoint } from "@handsoff/gesture";
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { GazeDebugOverlay } from "./GazeDebugOverlay";

const points: GazeOverlayPoint[] = [
  { x: 0.5, y: 0.5, kind: "iris" },
  { x: 0.4, y: 0.5, kind: "corner" },
  { x: 0.6, y: 0.5, kind: "corner" },
  { x: 0.5, y: 0.45, kind: "lid" },
  { x: 0.5, y: 0.55, kind: "lid" },
];

describe("GazeDebugOverlay", () => {
  it("draws the iris/corner/lid points and the live feature readout", () => {
    render(
      <GazeDebugOverlay
        stream={null}
        points={points}
        features={{ irisXL: 0.5, irisYL: 0.5, irisXR: 0.5, irisYR: 0.5, eyeAspect: 0.3 }}
      />,
    );
    expect(screen.getByLabelText("Eye tracking debug")).toBeInTheDocument();
    expect(screen.getByTestId("gaze-point-iris")).toBeInTheDocument();
    expect(screen.getAllByTestId("gaze-point-corner")).toHaveLength(2);
    expect(screen.getByText(/eye aspect/i)).toBeInTheDocument();
  });

  it("shows a no-face state when there are no features", () => {
    render(<GazeDebugOverlay stream={null} points={null} features={null} />);
    expect(screen.getByText(/no face detected/i)).toBeInTheDocument();
  });
});
