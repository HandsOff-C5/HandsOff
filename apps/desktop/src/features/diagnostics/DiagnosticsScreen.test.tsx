import type { PointingEvidence, SurfaceSnapshot } from "@handsoff/contracts";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { DiagnosticsScreen } from "./DiagnosticsScreen";
import type { GetStream } from "./useSharedWebcam";

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
const disagree = [v("gesture", 0.9, cursor), v("gaze", 0.5, slack)];

function fakeStream(): MediaStream {
  return { getTracks: () => [{ stop: vi.fn() }] } as unknown as MediaStream;
}

describe("DiagnosticsScreen", () => {
  it("renders the board (channel strips + master HUD) from the evidence", () => {
    render(<DiagnosticsScreen evidence={disagree} />);
    expect(screen.getByLabelText("Diagnostics board")).toBeInTheDocument();
    expect(screen.getByLabelText("Fusion HUD")).toBeInTheDocument();
    expect(screen.getAllByTestId("channel-strip")).toHaveLength(2);
  });

  it("gives every channel a camera monitor, idle until the camera starts", () => {
    render(<DiagnosticsScreen evidence={disagree} />);
    const monitors = screen.getAllByTestId("channel-monitor");
    expect(monitors).toHaveLength(2);
    expect(monitors.every((m) => m.dataset.active === "false")).toBe(true);
  });

  it("starts the shared camera and feeds the stream to every monitor", async () => {
    const getStream: GetStream = vi.fn().mockResolvedValue(fakeStream());
    render(<DiagnosticsScreen evidence={disagree} getStream={getStream} />);

    fireEvent.click(screen.getByRole("button", { name: /start camera/i }));

    await waitFor(() =>
      expect(screen.getByRole("button", { name: /stop camera/i })).toBeInTheDocument(),
    );
    expect(getStream).toHaveBeenCalledTimes(1);
    expect(screen.getAllByTestId("channel-monitor").every((m) => m.dataset.active === "true")).toBe(
      true,
    );
  });

  it("surfaces a camera error", async () => {
    const getStream: GetStream = vi.fn().mockRejectedValue(new Error("permission denied"));
    render(<DiagnosticsScreen evidence={disagree} getStream={getStream} />);
    fireEvent.click(screen.getByRole("button", { name: /start camera/i }));
    expect(await screen.findByRole("alert")).toHaveTextContent(/permission denied/);
  });

  it("draws the injected per-channel overlay in its monitor", () => {
    render(
      <DiagnosticsScreen
        evidence={disagree}
        overlayForChannel={(id) => <div data-testid={`overlay-${id}`} />}
      />,
    );
    expect(screen.getByTestId("overlay-gesture")).toBeInTheDocument();
    expect(screen.getByTestId("overlay-gaze")).toBeInTheDocument();
  });
});
