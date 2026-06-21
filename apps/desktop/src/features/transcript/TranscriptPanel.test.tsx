import type { SttError, SttStream } from "@handsoff/contracts";
import { FakeSttStream } from "@handsoff/testkit";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";

import { TranscriptPanel } from "./TranscriptPanel";

// A fresh fake per start() (matching the hook's per-start stream creation), with
// a handle on the most recent one so the test can drive its events.
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

async function flush() {
  await act(async () => {
    await Promise.resolve();
  });
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

  it("shows a live partial while speaking and replaces it as it revises", async () => {
    render(<TranscriptPanel createStream={makeFactory()} />);
    fireEvent.click(screen.getByRole("button", { name: "Speak" }));
    await flush();

    act(() => latest().emitPartial("hello"));
    expect(screen.getByTestId("transcript-partial")).toHaveTextContent("hello");

    act(() => latest().emitPartial("hello world"));
    expect(screen.getByTestId("transcript-partial")).toHaveTextContent("hello world");
  });

  it("renders a final transcript with confidence and latency, clearing the partial", async () => {
    render(<TranscriptPanel createStream={makeFactory()} />);
    fireEvent.click(screen.getByRole("button", { name: "Speak" }));
    await flush();

    act(() => latest().emitPartial("hello"));
    act(() => latest().emitFinal("hello world", 0.92, 180));

    expect(screen.getByText("hello world")).toBeInTheDocument();
    expect(screen.getByText(/92% · 180 ms/)).toBeInTheDocument();
    expect(screen.getByTestId("transcript-partial")).toHaveTextContent("");
  });

  it("accumulates multiple finals in order", async () => {
    render(<TranscriptPanel createStream={makeFactory()} />);
    fireEvent.click(screen.getByRole("button", { name: "Speak" }));
    await flush();

    act(() => latest().emitFinal("first", 1, 100));
    act(() => latest().emitFinal("second", 1, 110));

    const items = screen.getAllByRole("listitem");
    expect(items).toHaveLength(2);
    expect(items[0]).toHaveTextContent("first");
    expect(items[1]).toHaveTextContent("second");
  });

  it("shows a visible, recoverable error and resumes on retry", async () => {
    render(<TranscriptPanel createStream={makeFactory()} />);
    fireEvent.click(screen.getByRole("button", { name: "Speak" }));
    await flush();

    act(() => latest().emitError({ kind: "network", message: "dropped" }));
    expect(screen.getByRole("alert")).toHaveTextContent(/connection dropped/i);

    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    await flush();
    // A new session starts; the error clears and new partials render.
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    act(() => latest().emitPartial("recovered"));
    expect(screen.getByTestId("transcript-partial")).toHaveTextContent("recovered");
  });

  it("surfaces a mic-permission failure from start() rejection", async () => {
    render(
      <TranscriptPanel
        createStream={makeFactory({
          startError: { kind: "mic-permission", message: "denied" },
        })}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: "Speak" }));

    await waitFor(() =>
      expect(screen.getByRole("alert")).toHaveTextContent(/Microphone access denied/i),
    );
  });

  it("returns to idle after stop and stops mutating", async () => {
    render(<TranscriptPanel createStream={makeFactory()} />);
    fireEvent.click(screen.getByRole("button", { name: "Speak" }));
    await flush();
    act(() => latest().emitPartial("hello"));

    fireEvent.click(screen.getByRole("button", { name: "Stop" }));
    await flush();

    expect(screen.getByRole("button", { name: "Speak" })).toBeInTheDocument();
    expect(screen.getByTestId("transcript-partial")).toHaveTextContent("");
  });
});
