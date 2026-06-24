import { describe, expect, it, vi } from "vitest";

const closeHand = vi.fn();

vi.mock("@mediapipe/tasks-vision", () => ({
  FilesetResolver: {
    forVisionTasks: vi.fn(async () => ({ wasm: true })),
  },
  HandLandmarker: {
    createFromOptions: vi.fn(async () => ({
      detectForVideo: vi.fn(),
      close: closeHand,
    })),
  },
  FaceLandmarker: {
    createFromOptions: vi.fn(async () => {
      throw new Error("missing face model");
    }),
  },
}));

describe("createHandLandmarker", () => {
  it("wraps MediaPipe model-load failures in a typed error and closes partial handles", async () => {
    const { createHandLandmarker, MediaPipeModelLoadError } = await import("./handLandmarker");

    let error: unknown;
    try {
      await createHandLandmarker();
    } catch (caught) {
      error = caught;
    }

    expect(error).toBeInstanceOf(MediaPipeModelLoadError);
    expect(error).toMatchObject({
      kind: "model-load",
      task: "vision-landmarker",
    });
    expect(closeHand).toHaveBeenCalledOnce();
  });
});
