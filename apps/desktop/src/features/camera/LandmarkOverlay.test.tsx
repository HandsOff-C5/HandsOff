import type { Hand, LandmarkFrame } from "@handsoff/contracts";
import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { LandmarkOverlay } from "./LandmarkOverlay";

const hand = (handedness: Hand["handedness"], score: number): Hand => ({
  landmarks: Array.from({ length: 21 }, (_, i) => ({
    x: i / 21,
    y: i / 21,
    z: 0,
    visibility: 1,
  })),
  handedness,
  score,
});

const frame = (...hands: Hand[]): LandmarkFrame => ({ timestampMs: 0, hands });

describe("LandmarkOverlay", () => {
  it("shows a no-hand message when there is no frame", () => {
    render(<LandmarkOverlay frame={null} fps={0} />);
    expect(screen.getByText(/no hand detected/i)).toBeInTheDocument();
  });

  it("shows a no-hand message when the frame has no hands", () => {
    render(<LandmarkOverlay frame={frame()} fps={30} />);
    expect(screen.getByText(/no hand detected/i)).toBeInTheDocument();
  });

  it("renders all 21 landmark markers for a detected hand", () => {
    render(<LandmarkOverlay frame={frame(hand("Right", 0.9))} fps={30} />);
    expect(screen.getAllByTestId("landmark")).toHaveLength(21);
  });

  it("renders markers for every hand when two are detected", () => {
    render(<LandmarkOverlay frame={frame(hand("Right", 0.9), hand("Left", 0.8))} fps={30} />);
    expect(screen.getAllByTestId("landmark")).toHaveLength(42);
  });

  it("labels each hand with its handedness and rounded confidence", () => {
    render(<LandmarkOverlay frame={frame(hand("Right", 0.92))} fps={30} />);
    const readout = screen.getByTestId("hand-readout-0");
    expect(within(readout).getByText(/right/i)).toBeInTheDocument();
    expect(within(readout).getByText(/92%/)).toBeInTheDocument();
  });

  it("shows the FPS readout", () => {
    render(<LandmarkOverlay frame={frame(hand("Right", 0.9))} fps={12.4} />);
    expect(screen.getByText(/12 fps/i)).toBeInTheDocument();
  });
});
