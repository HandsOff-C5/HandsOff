import type { LandmarkFrame } from "@handsoff/contracts";
import * as gesture from "@handsoff/gesture";
import type { RawHandLandmarkerResult } from "@handsoff/gesture";
import { act, fireEvent, render, screen, within } from "@testing-library/react";
import { beforeAll, describe, expect, it, vi } from "vitest";

import { CameraPanel } from "./CameraPanel";
import type { DisplayInfo, GestureOverlay } from "./useGestureOverlay";

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

// A stand-in overlay that reports a single 1920×1080 display without touching Tauri, so the
// camera panel can reach a calibrated-capable live state in jsdom.
const fakeOverlay = (): GestureOverlay => {
  const noop = () => {};
  const displays: DisplayInfo[] = [
    { id: "1", isMain: true, x: 0, y: 0, width: 1920, height: 1080 },
  ];
  return {
    start: () => Promise.resolve(displays),
    stop: () => Promise.resolve(),
    move: noop,
    target: noop,
    untarget: noop,
    clear: noop,
  };
};

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
    expect(await screen.findByText(/^Live\b/)).toBeInTheDocument();
  });

  it("lists available cameras once live and switches stream on selection", async () => {
    const devices = [
      { deviceId: "cam-1", label: "FaceTime HD", kind: "videoinput" },
      { deviceId: "cam-2", label: "External USB", kind: "videoinput" },
    ] as MediaDeviceInfo[];
    const getStream = vi.fn(() => Promise.resolve(fakeStream()));

    render(
      <CameraPanel
        getStream={getStream}
        createDetector={() => Promise.resolve(fakeDetector())}
        listDevices={() => Promise.resolve(devices)}
      />,
    );
    startCamera();

    const picker = await screen.findByRole("combobox", { name: /camera/i });
    expect(within(picker).getByRole("option", { name: /facetime hd/i })).toBeInTheDocument();
    expect(within(picker).getByRole("option", { name: /external usb/i })).toBeInTheDocument();

    fireEvent.change(picker, { target: { value: "cam-2" } });
    await screen.findByText(/^Live\b/);
    expect(getStream).toHaveBeenLastCalledWith("cam-2");
  });

  it("offers a mirror (selfie-view) toggle once live", async () => {
    render(
      <CameraPanel
        getStream={() => Promise.resolve(fakeStream())}
        createDetector={() => Promise.resolve(fakeDetector())}
      />,
    );
    startCamera();
    expect(await screen.findByRole("checkbox", { name: /mirror/i })).toBeInTheDocument();
  });

  it("offers Calibrate and Dump-frames controls once live", async () => {
    render(
      <CameraPanel
        getStream={() => Promise.resolve(fakeStream())}
        createDetector={() => Promise.resolve(fakeDetector())}
      />,
    );
    startCamera();
    expect(await screen.findByRole("button", { name: /calibrate/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /dump frames/i })).toBeInTheDocument();
  });

  it("enters per-display calibration when Calibrate is pressed", async () => {
    render(
      <CameraPanel
        getStream={() => Promise.resolve(fakeStream())}
        createDetector={() => Promise.resolve(fakeDetector())}
        overlay={fakeOverlay()}
      />,
    );
    startCamera();
    fireEvent.click(await screen.findByRole("button", { name: /calibrate/i }));
    expect(screen.getByText(/0\s*\/\s*9/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /capture/i })).toBeInTheDocument();
  });

  it("calls onGestureCursor with a point when hands are present and null when no hands", async () => {
    // Capture the onResult callback injected into createLandmarkProcessor so we can
    // trigger frames directly without relying on the rAF loop running in jsdom.
    let capturedOnResult: ((result: { frame: LandmarkFrame; fps: number }) => void) | undefined;
    const processorSpy = vi.spyOn(gesture, "createLandmarkProcessor").mockImplementation((opts) => {
      capturedOnResult = opts.onResult;
      return { process: vi.fn() };
    });

    const onGestureCursor = vi.fn();
    render(
      <CameraPanel
        getStream={() => Promise.resolve(fakeStream())}
        createDetector={() => Promise.resolve(fakeDetector())}
        overlay={fakeOverlay()}
        onGestureCursor={onGestureCursor}
      />,
    );
    startCamera();
    await screen.findByText(/^Live\b/);
    expect(capturedOnResult).toBeDefined();

    // Frame with one hand present — should call onGestureCursor with a point.
    const fakeLandmark = { x: 0.5, y: 0.5, z: 0, visibility: 1 };
    const frameWithHand: LandmarkFrame = {
      timestampMs: 1,
      hands: [
        {
          landmarks: Array(21).fill(fakeLandmark) as LandmarkFrame["hands"][0]["landmarks"],
          handedness: "Right",
          score: 0.9,
        },
      ],
    };
    act(() => {
      capturedOnResult!({ frame: frameWithHand, fps: 30 });
    });
    expect(onGestureCursor).toHaveBeenLastCalledWith(
      expect.objectContaining({ x: expect.any(Number), y: expect.any(Number) }),
    );

    // Frame with no hands — should call onGestureCursor with null.
    const frameNoHands: LandmarkFrame = { timestampMs: 2, hands: [] };
    act(() => {
      capturedOnResult!({ frame: frameNoHands, fps: 30 });
    });
    expect(onGestureCursor).toHaveBeenLastCalledWith(null);

    processorSpy.mockRestore();
  });
});
