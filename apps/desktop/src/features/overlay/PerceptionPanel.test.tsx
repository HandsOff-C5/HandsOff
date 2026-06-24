import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { PerceptionPanel } from "./PerceptionPanel";
import { IDLE_SUPERVISOR_SNAPSHOT, type SupervisorSnapshot } from "./supervisor-signal";

const snapshot: SupervisorSnapshot = {
  hand: { point: [0.3, 0.4], confidence: 0.92, fps: 30, lock: "Calculator" },
  gaze: { point: [0.6, 0.2], confidence: 0.61, fps: 24, lock: "Mail" },
  voice: { state: "listening", transcript: "press seven" },
  agent: { action: null, pendingApproval: false },
};

describe("PerceptionPanel", () => {
  it("shows one row per tracker with its confidence, rate, and lock", () => {
    render(<PerceptionPanel snapshot={snapshot} />);
    const hand = screen.getByTestId("perception-row-hand");
    expect(within(hand).getByText("Hand")).toBeInTheDocument();
    expect(within(hand).getByText("92%")).toBeInTheDocument();
    expect(within(hand).getByText("30fps")).toBeInTheDocument();
    expect(within(hand).getByText("Calculator")).toBeInTheDocument();
    expect(hand).toHaveAttribute("data-status", "live");

    const gaze = screen.getByTestId("perception-row-gaze");
    expect(within(gaze).getByText("Eyes")).toBeInTheDocument();
    expect(within(gaze).getByText("61%")).toBeInTheDocument();
    expect(within(gaze).getByText("Mail")).toBeInTheDocument();
    expect(gaze).toHaveAttribute("data-status", "live");
  });

  it("reddens a tracker that lost its fix (point null → lost)", () => {
    render(
      <PerceptionPanel
        snapshot={{
          ...snapshot,
          hand: { point: null, confidence: 0, fps: 0, lock: null },
        }}
      />,
    );
    const hand = screen.getByTestId("perception-row-hand");
    expect(hand).toHaveAttribute("data-status", "lost");
    expect(within(hand).getByText("—")).toBeInTheDocument();
  });

  it("shows the voice row's engagement state and live lamp", () => {
    render(<PerceptionPanel snapshot={snapshot} />);
    const voice = screen.getByTestId("perception-row-voice");
    expect(within(voice).getByText("Voice")).toBeInTheDocument();
    expect(voice).toHaveAttribute("data-status", "live");
  });

  it("marks the voice row idle (not live) when nothing is engaged", () => {
    render(<PerceptionPanel snapshot={IDLE_SUPERVISOR_SNAPSHOT} />);
    expect(screen.getByTestId("perception-row-voice")).toHaveAttribute("data-status", "idle");
  });
});
