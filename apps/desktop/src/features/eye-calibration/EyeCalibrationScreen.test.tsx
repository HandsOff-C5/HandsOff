import type { MonitorRect } from "@handsoff/gesture";
import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { EyeCalibrationScreen } from "./EyeCalibrationScreen";

const TWO_SCREENS: MonitorRect[] = [
  { x: 0, y: 0, w: 1000, h: 800 },
  { x: 1000, y: 0, w: 500, h: 500 },
];

// Webcam that never resolves → tracking stays "loading" (not denied); the stage still
// renders its dots, so we can assert the monitor wiring without a real camera.
const pendingCamera = { getStream: () => new Promise<MediaStream>(() => undefined) };

describe("EyeCalibrationScreen", () => {
  it("loads the monitors and starts on screen 1's first dot, composed into union space", async () => {
    render(
      <EyeCalibrationScreen
        monitorsProvider={() => Promise.resolve(TWO_SCREENS)}
        tracking={pendingCamera}
        persist={vi.fn()}
      />,
    );

    const hud = await screen.findByTestId("eyecal-hud");
    expect(hud).toHaveTextContent(/Screen 1 of 2/);
    expect(hud).toHaveTextContent(/dot 1\/9/);

    // Dot 0 → laptop local (0.12,0.12) → global (120,96); union is 1500×800 from (0,0),
    // so union-normalized x = 120/1500 = 8%, y = 96/800 = 12%.
    const dot = await screen.findByTestId("eyecal-dot");
    expect(dot.style.left).toBe("8%");
    expect(dot.style.top).toBe("12%");
  });

  it("shows the preparing state until monitors resolve", async () => {
    let resolve: (m: MonitorRect[]) => void = () => undefined;
    render(
      <EyeCalibrationScreen
        monitorsProvider={() => new Promise<MonitorRect[]>((r) => (resolve = r))}
        tracking={pendingCamera}
        persist={vi.fn()}
      />,
    );
    expect(screen.getByTestId("eyecal-loading")).toBeInTheDocument();
    resolve(TWO_SCREENS);
    expect(await screen.findByTestId("eyecal-stage")).toBeInTheDocument();
  });
});
