import type { PointingEvidence, SurfaceSnapshot } from "@handsoff/contracts";
import { fuseEvidence } from "@handsoff/intent";
import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { FusionHud } from "./FusionHud";

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

// Hand points at Cursor (0.9); gaze drifts to Slack (0.5) → acts on Cursor, flags gaze.
const disagree = fuseEvidence([v("gesture", 0.9, cursor), v("gaze", 0.5, slack)]);

describe("FusionHud", () => {
  it("renders a row per fused target with its confidence percentage", () => {
    render(<FusionHud fusion={disagree} />);
    expect(screen.getByText(/Cursor — editor/)).toBeInTheDocument();
    expect(screen.getByText(/Slack — general/)).toBeInTheDocument();
    expect(screen.getByText("90%")).toBeInTheDocument();
    expect(screen.getByText("50%")).toBeInTheDocument();
  });

  it("marks the winning target as the one being acted on", () => {
    render(<FusionHud fusion={disagree} />);
    const targets = screen.getAllByTestId("fusion-target");
    const winner = targets.find((el) => el.dataset.winner === "true");
    expect(winner).toBeDefined();
    expect(within(winner as HTMLElement).getByText(/Cursor — editor/)).toBeInTheDocument();
  });

  it("renders the per-source votes for a target", () => {
    render(<FusionHud fusion={disagree} />);
    expect(screen.getByText(/gesture/)).toBeInTheDocument();
    expect(screen.getByText(/gaze/)).toBeInTheDocument();
  });

  it("shows the DRAG line naming the noisy channel", () => {
    render(<FusionHud fusion={disagree} />);
    const drag = screen.getByTestId("fusion-drag");
    expect(drag).toHaveTextContent(/gaze/);
    expect(drag).toHaveTextContent(/Slack/);
  });

  it("shows the decision", () => {
    render(<FusionHud fusion={disagree} />);
    expect(screen.getByTestId("fusion-decision")).toHaveTextContent(/act/i);
  });

  it("renders no drag line when the bind is clean", () => {
    const clean = fuseEvidence([v("gesture", 0.9, cursor), v("gaze", 0.6, cursor)]);
    render(<FusionHud fusion={clean} />);
    expect(screen.queryByTestId("fusion-drag")).not.toBeInTheDocument();
  });

  it("renders an idle HUD when there is no fusion", () => {
    render(<FusionHud fusion={null} />);
    expect(screen.getByText(/no signal/i)).toBeInTheDocument();
  });
});
