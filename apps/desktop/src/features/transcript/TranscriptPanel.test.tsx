import type { SttError, SttStream } from "@handsoff/contracts";
import { FakeSttStream } from "@handsoff/testkit";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";

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
});
