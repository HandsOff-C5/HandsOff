import type { PointingEvidence, SurfaceSnapshot } from "@handsoff/contracts";
import { fireEvent, render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { DiagnosticsBoard } from "./DiagnosticsBoard";

const cursor: SurfaceSnapshot = {
  id: "win:cursor",
  app: "Cursor",
  title: "editor",
  availability: "available",
  accessStatus: "accessible",
};
const slack: SurfaceSnapshot = {
  id: "win:slack",
  app: "Slack",
  title: "general",
  availability: "available",
  accessStatus: "accessible",
};
const v = (
  source: PointingEvidence["source"],
  confidence: number,
  surface: SurfaceSnapshot,
): PointingEvidence => ({ source, confidence, strategy: source, surface });

// Hand → Cursor (0.9), gaze → Slack (0.5): acts on Cursor, flags gaze as the drag.
const disagree = [v("gesture", 0.9, cursor), v("gaze", 0.5, slack)];

function stripFor(label: string): HTMLElement {
  const strip = screen
    .getAllByTestId("channel-strip")
    .find((el) => within(el).queryByText(label) !== null);
  if (!strip) throw new Error(`no channel strip for ${label}`);
  return strip;
}

describe("DiagnosticsBoard", () => {
  it("renders a strip per channel and the master fusion HUD", () => {
    render(<DiagnosticsBoard evidence={disagree} />);
    expect(stripFor("Hand")).toBeInTheDocument();
    expect(stripFor("Gaze")).toBeInTheDocument();
    expect(screen.getByLabelText("Fusion HUD")).toBeInTheDocument();
    // The disagreement is flagged on the master bus.
    expect(screen.getByTestId("fusion-drag")).toHaveTextContent(/gaze/);
  });

  it("muting a channel re-fuses live — the drag disappears", () => {
    render(<DiagnosticsBoard evidence={disagree} />);
    expect(screen.getByTestId("fusion-drag")).toBeInTheDocument();

    fireEvent.click(within(stripFor("Gaze")).getByRole("button", { name: /mute/i }));

    // With gaze muted, only the hand vote remains → a clean Cursor bind, no drag.
    expect(screen.queryByTestId("fusion-drag")).not.toBeInTheDocument();
  });

  it("soloing a channel drives fusion from only that channel", () => {
    render(<DiagnosticsBoard evidence={disagree} />);
    fireEvent.click(within(stripFor("Gaze")).getByRole("button", { name: /solo/i }));

    // Soloing gaze (Slack 0.5) → its target wins the master bus.
    const winner = screen
      .getAllByTestId("fusion-target")
      .find((el) => el.dataset.winner === "true");
    expect(winner).toBeDefined();
    expect(within(winner as HTMLElement).getByText(/Slack/)).toBeInTheDocument();
  });

  it("renders a per-channel input-monitor slot when provided", () => {
    render(
      <DiagnosticsBoard
        evidence={disagree}
        renderMonitor={(id) => <div data-testid={`monitor-${id}`} />}
      />,
    );
    expect(screen.getByTestId("monitor-gesture")).toBeInTheDocument();
    expect(screen.getByTestId("monitor-gaze")).toBeInTheDocument();
  });
});
