import type { SttError, SttStream } from "@handsoff/contracts";
import { FakeSttStream } from "@handsoff/testkit";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const tauri = vi.hoisted(() => ({
  invoke: vi.fn(),
  listen: vi.fn(),
}));

vi.mock("@tauri-apps/api/core", () => ({ invoke: tauri.invoke }));
vi.mock("@tauri-apps/api/event", () => ({ listen: tauri.listen }));

// A fresh fake per capture (matching the controller's per-press stream
// creation), with a handle on the most recent one so the test can drive events.
let fakes: FakeSttStream[];
function makeFactory(options?: { startError?: SttError }) {
  fakes = [];
  return (): SttStream => {
    const fake = new FakeSttStream(options?.startError ? { startError: options.startError } : {});
    fakes.push(fake);
    return fake;
  };
}
function latest(): FakeSttStream {
  const fake = fakes[fakes.length - 1];
  if (!fake) throw new Error("no fake stream created yet");
  return fake;
}

import {
  CAPTURE_HOTKEY_EVENT,
  type CaptureHotkeyListenEvent,
} from "../head-pointing/useCaptureHotkey";
import { TranscriptPanel } from "./TranscriptPanel";

async function flush() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

function talkButton() {
  return screen.getByRole("button", { name: /Hold to talk|Release to send/ });
}

beforeEach(() => {
  fakes = [];
  tauri.invoke.mockReset();
  tauri.listen.mockReset();
  Reflect.deleteProperty(window, "__TAURI_INTERNALS__");
});

describe("TranscriptPanel", () => {
  it("renders an unavailable state without a native backend", () => {
    render(<TranscriptPanel />);
    expect(screen.getByRole("heading", { level: 2, name: "Transcript" })).toBeInTheDocument();
    expect(screen.getByText(/Mac app required/i)).toBeInTheDocument();
  });

  it("captures on hold and shows the live partial while speaking", async () => {
    render(<TranscriptPanel createStream={makeFactory()} />);
    fireEvent.pointerDown(talkButton());
    await flush();
    expect(talkButton()).toHaveTextContent("Release to send");

    act(() => latest().emitPartial("hello"));
    expect(screen.getByTestId("transcript-partial")).toHaveTextContent("hello");
    act(() => latest().emitPartial("hello world"));
    expect(screen.getByTestId("transcript-partial")).toHaveTextContent("hello world");
  });

  it("delivers one stable final utterance on release and clears the partial", async () => {
    render(<TranscriptPanel createStream={makeFactory()} />);
    const button = talkButton();
    fireEvent.pointerDown(button);
    await flush();

    act(() => latest().emitFinal("open the issue", 0.9, 120));
    act(() => latest().emitPartial("and brief the agent"));

    fireEvent.pointerUp(talkButton());
    await flush();

    // One capture → one final transcript: both segments fused into a single item.
    const items = screen.getAllByRole("listitem");
    expect(items).toHaveLength(1);
    expect(items[0]).toHaveTextContent("open the issue and brief the agent");
    expect(screen.getByText(/90% · 120 ms/)).toBeInTheDocument();
    expect(screen.getByTestId("transcript-partial")).toHaveTextContent("");
    expect(talkButton()).toHaveTextContent("Hold to talk");
  });

  it("notifies the intent lane when a final utterance is delivered", async () => {
    const onFinalTranscript = vi.fn();
    render(<TranscriptPanel createStream={makeFactory()} onFinalTranscript={onFinalTranscript} />);
    const button = talkButton();
    fireEvent.pointerDown(button);
    await flush();

    act(() => latest().emitFinal("click there", 0.9, 120));
    fireEvent.pointerUp(talkButton());
    await flush();

    expect(onFinalTranscript).toHaveBeenCalledWith(
      expect.objectContaining({ kind: "final", text: "click there", confidence: 0.9 }),
    );
  });

  it("cancel discards the in-flight capture without delivering a final", async () => {
    render(<TranscriptPanel createStream={makeFactory()} />);
    fireEvent.pointerDown(talkButton());
    await flush();
    act(() => latest().emitFinal("open the issue", 1, 100));

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    await flush();

    expect(screen.queryAllByRole("listitem")).toHaveLength(0);
    expect(screen.getByTestId("transcript-partial")).toHaveTextContent("");
    expect(latest().stopCallCount).toBe(1);
    expect(talkButton()).toHaveTextContent("Hold to talk");
  });

  it("accumulates one final per capture across multiple holds", async () => {
    render(<TranscriptPanel createStream={makeFactory()} />);
    fireEvent.pointerDown(talkButton());
    await flush();
    act(() => latest().emitFinal("first command", 1, 100));
    fireEvent.pointerUp(talkButton());
    await flush();

    fireEvent.pointerDown(talkButton());
    await flush();
    act(() => latest().emitFinal("second command", 1, 110));
    fireEvent.pointerUp(talkButton());
    await flush();

    const items = screen.getAllByRole("listitem");
    expect(items).toHaveLength(2);
    expect(items[0]).toHaveTextContent("first command");
    expect(items[1]).toHaveTextContent("second command");
  });

  it("shows a visible, recoverable error and resumes on a fresh hold", async () => {
    render(<TranscriptPanel createStream={makeFactory()} />);
    fireEvent.pointerDown(talkButton());
    await flush();

    act(() => latest().emitError({ kind: "network", message: "dropped" }));
    await flush();
    expect(screen.getByRole("alert")).toHaveTextContent(/connection dropped/i);
    const erroredStream = latest();

    fireEvent.pointerDown(talkButton());
    await flush();
    // The abandoned stream was released (mic + socket), not left feeding events.
    expect(erroredStream.stopCallCount).toBe(1);
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    act(() => latest().emitPartial("recovered"));
    expect(screen.getByTestId("transcript-partial")).toHaveTextContent("recovered");
  });

  it("surfaces a mic-permission failure from start() rejection", async () => {
    render(
      <TranscriptPanel
        createStream={makeFactory({ startError: { kind: "mic-permission", message: "denied" } })}
      />,
    );
    fireEvent.pointerDown(talkButton());

    await waitFor(() =>
      expect(screen.getByRole("alert")).toHaveTextContent(/Microphone access denied/i),
    );
  });

  it("surfaces a hosted token failure as a retryable provider error", async () => {
    render(
      <TranscriptPanel
        createStream={makeFactory({
          startError: {
            kind: "provider-unavailable",
            message: "Could not obtain a streaming token",
          },
        })}
      />,
    );
    fireEvent.pointerDown(talkButton());

    await waitFor(() =>
      expect(screen.getByRole("alert")).toHaveTextContent(/speech service is unavailable.*retry/i),
    );
    expect(talkButton()).toHaveTextContent("Hold to talk");
  });

  it("points first-run speech authorization failures to the Permissions allow flow", async () => {
    render(
      <TranscriptPanel
        createStream={makeFactory({
          startError: {
            kind: "mic-permission",
            message: "speech recognition not authorized (0)",
          },
        })}
      />,
    );
    fireEvent.pointerDown(talkButton());

    await waitFor(() =>
      expect(screen.getByRole("alert")).toHaveTextContent(/Allow camera, microphone & speech/i),
    );
  });

  it("points denied speech authorization failures to System Settings", async () => {
    render(
      <TranscriptPanel
        createStream={makeFactory({
          startError: {
            kind: "mic-permission",
            message: "speech recognition not authorized (1)",
          },
        })}
      />,
    );
    fireEvent.pointerDown(talkButton());

    await waitFor(() =>
      expect(screen.getByRole("alert")).toHaveTextContent(/System Settings.*Speech Recognition/i),
    );
  });

  it("surfaces the native start-failed reason when recognition exits before ready", async () => {
    render(
      <TranscriptPanel
        createStream={makeFactory({
          startError: {
            kind: "start-failed",
            message: "On-device recognition exited before the microphone was ready",
          },
        })}
      />,
    );
    fireEvent.pointerDown(talkButton());

    await waitFor(() =>
      expect(screen.getByRole("alert")).toHaveTextContent(
        /On-device recognition exited before the microphone was ready/i,
      ),
    );
  });

  it("starts full capture with head pointer config and recenters while capturing", async () => {
    Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: {} });
    const headPointer = { movementMode: "edge" as const, speed: 5, distanceToEdge: 0.12 };
    tauri.listen.mockResolvedValue(vi.fn());
    tauri.invoke.mockImplementation(async (command: string) => {
      if (command === "request_media_permissions") {
        return { speech: "granted", microphone: "granted", camera: "granted" };
      }
      return undefined;
    });

    render(<TranscriptPanel createStream={makeFactory()} headPointer={headPointer} />);

    fireEvent.pointerDown(screen.getByRole("button", { name: "Hold to capture (head + voice)" }));
    await flush();

    await waitFor(() =>
      expect(tauri.invoke).toHaveBeenCalledWith("head_track_start", { headPointer }),
    );
    fireEvent.click(screen.getByRole("button", { name: "Recenter" }));
    expect(tauri.invoke).toHaveBeenCalledWith("head_track_recenter");

    fireEvent.pointerUp(screen.getByRole("button", { name: "Release (head + voice)" }));
    await flush();
    expect(tauri.invoke).toHaveBeenCalledWith("head_track_stop");
  });

  it("does not start full capture when permission work resolves after release", async () => {
    Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: {} });
    tauri.listen.mockResolvedValue(vi.fn());
    let resolvePermissions:
      | ((permissions: { speech: string; microphone: string; camera: string }) => void)
      | null = null;
    tauri.invoke.mockImplementation((command: string) => {
      if (command === "request_media_permissions") {
        return new Promise((resolve) => {
          resolvePermissions = resolve;
        });
      }
      return Promise.resolve(undefined);
    });

    render(<TranscriptPanel createStream={makeFactory()} />);

    fireEvent.pointerDown(screen.getByRole("button", { name: "Hold to capture (head + voice)" }));
    fireEvent.pointerUp(screen.getByRole("button", { name: "Hold to capture (head + voice)" }));
    await act(async () => {
      resolvePermissions?.({ speech: "granted", microphone: "granted", camera: "granted" });
    });
    await flush();

    expect(tauri.invoke).not.toHaveBeenCalledWith("head_track_start", expect.anything());
    expect(fakes).toHaveLength(0);
  });

  it("does not start voice capture when full-capture head tracking fails", async () => {
    Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: {} });
    tauri.listen.mockResolvedValue(vi.fn());
    tauri.invoke.mockImplementation(async (command: string) => {
      if (command === "request_media_permissions") {
        return { speech: "granted", microphone: "granted", camera: "granted" };
      }
      if (command === "head_track_start") {
        throw new Error("head-track sidecar unavailable");
      }
      return undefined;
    });

    render(<TranscriptPanel createStream={makeFactory()} />);

    fireEvent.pointerDown(screen.getByRole("button", { name: "Hold to capture (head + voice)" }));

    expect(await screen.findByText("head-track sidecar unavailable")).toBeInTheDocument();
    expect(fakes).toHaveLength(0);
  });

  it("shows Recenter for the Command+Option+/ hotkey capture path", async () => {
    Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: {} });
    let hotkeyHandler: ((event: CaptureHotkeyListenEvent) => void) | null = null;
    tauri.listen.mockImplementation(
      async (event: string, next: (event: CaptureHotkeyListenEvent) => void) => {
        if (event === CAPTURE_HOTKEY_EVENT) hotkeyHandler = next;
        return vi.fn();
      },
    );
    tauri.invoke.mockResolvedValue(undefined);

    render(<TranscriptPanel createStream={makeFactory()} />);
    await waitFor(() => expect(hotkeyHandler).not.toBeNull());

    act(() => hotkeyHandler?.({ payload: { phase: "start" } }));
    await waitFor(() => expect(tauri.invoke).toHaveBeenCalledWith("head_track_start", undefined));
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Recenter" })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole("button", { name: "Recenter" }));
    expect(tauri.invoke).toHaveBeenCalledWith("head_track_recenter");

    act(() => hotkeyHandler?.({ payload: { phase: "stop" } }));
    await waitFor(() =>
      expect(tauri.invoke.mock.calls.some(([command]) => command === "head_track_stop")).toBe(true),
    );
  });
});
