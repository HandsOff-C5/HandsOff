import type { RawHandLandmarkerResult } from "@handsoff/gesture";
import { fireEvent, render, screen } from "@testing-library/react";
import { beforeAll, describe, expect, it, vi } from "vitest";

import { CameraPanel } from "./CameraPanel";

// jsdom has no media pipeline; the panel calls video.play() (and catches its failure).
// Stub it so the suite output stays clean.
beforeAll(() => {
  vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue();
});

const fakeDetector = () => ({
  detector: { detectForVideo: (): RawHandLandmarkerResult => ({ landmarks: [] }) },
  close: vi.fn(),
});

const fakeStream = () => ({ getTracks: () => [] }) as unknown as MediaStream;

const startCamera = () => fireEvent.click(screen.getByRole("button", { name: /start camera/i }));

describe("CameraPanel", () => {
  it("does not touch the camera until the user starts it (idle by default)", () => {
    const getStream = vi.fn(() => new Promise<MediaStream>(() => {}));
    render(<CameraPanel getStream={getStream} createDetector={() => new Promise(() => {})} />);

    expect(screen.getByRole("button", { name: /start camera/i })).toBeInTheDocument();
    expect(screen.getByText(/no hand detected/i)).toBeInTheDocument();
    expect(getStream).not.toHaveBeenCalled();
  });

  it("shows a starting state after start while the camera and detector come up", () => {
    render(
      <CameraPanel
        getStream={() => new Promise(() => {})}
        createDetector={() => new Promise(() => {})}
      />,
    );
    startCamera();
    expect(screen.getByText(/starting camera/i)).toBeInTheDocument();
  });

  it("surfaces a permission error without crashing the dashboard", async () => {
    render(
      <CameraPanel
        getStream={() => Promise.reject(new Error("Permission denied"))}
        createDetector={() => Promise.resolve(fakeDetector())}
      />,
    );
    startCamera();
    expect(await screen.findByText(/permission denied/i)).toBeInTheDocument();
    // The overlay (and the rest of the dashboard) still renders.
    expect(screen.getByText(/no hand detected/i)).toBeInTheDocument();
  });

  it("reaches a live state once the camera and detector resolve", async () => {
    render(
      <CameraPanel
        getStream={() => Promise.resolve(fakeStream())}
        createDetector={() => Promise.resolve(fakeDetector())}
      />,
    );
    startCamera();
    expect(await screen.findByText(/^live$/i)).toBeInTheDocument();
  });
});
