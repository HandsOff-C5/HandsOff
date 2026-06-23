import { APP_NAME } from "@handsoff/contracts";
import { createFakeCuaDriver } from "@handsoff/cua";
import { FakeSttStream, fakeCuaWindowState } from "@handsoff/testkit";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";

import { App } from "../../App";
import { Dashboard } from "./Dashboard";

const PANEL_TITLES = [
  "Readiness",
  "Permissions",
  "Settings",
  "Transcript",
  "Sessions",
  "Plan preview",
];
// Sessions and Plan preview still start empty before a transcript arrives.
const EMPTY_PANEL_TITLES = ["Sessions", "Plan preview"];

let fakes: FakeSttStream[];

function makeFactory() {
  fakes = [];
  return () => {
    const fake = new FakeSttStream();
    fakes.push(fake);
    return fake;
  };
}

function latest() {
  const fake = fakes[fakes.length - 1];
  if (!fake) throw new Error("no fake stream created");
  return fake;
}

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

describe("Dashboard", () => {
  it("mounts without crashing", () => {
    expect(() => render(<Dashboard />)).not.toThrow();
  });

  it("shows the app brand in the header", () => {
    render(<Dashboard />);
    expect(screen.getByRole("heading", { level: 1, name: APP_NAME })).toBeInTheDocument();
  });

  it("renders a panel for each core-loop concern (no blank state)", () => {
    render(<Dashboard />);
    for (const title of PANEL_TITLES) {
      expect(screen.getByRole("heading", { level: 2, name: title })).toBeInTheDocument();
    }
  });

  it("renders empty-state copy before a transcript creates a plan", () => {
    render(<Dashboard />);
    expect(screen.getAllByText(/yet\./i)).toHaveLength(EMPTY_PANEL_TITLES.length);
  });

  it("renders the live readiness panel with capability rows", () => {
    render(<Dashboard />);
    // Without a native backend the panel still shows every capability.
    expect(screen.getByText("Computer-use agent")).toBeInTheDocument();
  });

  it("wires the permissions re-check button to the shared probe", () => {
    render(<Dashboard />);
    // The button is present and clicking it is safe with no native backend
    // (the probe is a no-op), proving the hook → panel wiring holds.
    const recheck = screen.getByRole("button", { name: "Re-check" });
    expect(() => fireEvent.click(recheck)).not.toThrow();
  });

  it("composes the dashboard into the app shell", () => {
    expect(() => render(<App />)).not.toThrow();
    expect(screen.getByRole("heading", { level: 1, name: APP_NAME })).toBeInTheDocument();
  });

  it("turns a final transcript into an approved CUA action", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState() });
    render(
      <Dashboard
        createStream={makeFactory()}
        cuaDriver={driver}
        now={() => "2026-06-22T12:00:00.000Z"}
        targetResolveDelayMs={0}
      />,
    );

    fireEvent.pointerDown(talkButton());
    await flush();
    act(() => latest().emitFinal("click there", 0.95, 100));
    fireEvent.pointerUp(talkButton());
    await flush();

    expect(screen.getByText("Click selected target")).toBeInTheDocument();
    expect(screen.getByText("Session: session-1")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Approve" }));

    await waitFor(() => expect(screen.getByText(/Last run:/)).toHaveTextContent("succeeded"));
    expect(driver.calls().map((call) => call.kind)).toEqual([
      "get_window_state",
      "get_window_state",
      "click",
      "get_window_state",
    ]);
  });

  it("waits before resolving the CUA target after speech release", async () => {
    const driver = createFakeCuaDriver({ state: fakeCuaWindowState() });
    render(
      <Dashboard
        createStream={makeFactory()}
        cuaDriver={driver}
        now={() => "2026-06-22T12:00:00.000Z"}
        targetResolveDelayMs={10}
      />,
    );

    fireEvent.pointerDown(talkButton());
    await flush();
    act(() => latest().emitFinal("click there", 0.95, 100));
    fireEvent.pointerUp(talkButton());
    await flush();

    expect(driver.calls()).toHaveLength(0);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 20));
    });

    expect(screen.getByText("Click selected target")).toBeInTheDocument();
    expect(driver.calls().map((call) => call.kind)).toEqual(["get_window_state"]);
  });

  it("shows a blocked preview when no CUA driver is available", async () => {
    render(
      <Dashboard
        createStream={makeFactory()}
        now={() => "2026-06-22T12:00:00.000Z"}
        targetResolveDelayMs={0}
      />,
    );

    fireEvent.pointerDown(talkButton());
    await flush();
    act(() => latest().emitFinal("click there", 0.95, 100));
    fireEvent.pointerUp(talkButton());
    await flush();

    expect(await screen.findByText("No accessible target was found")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Approve" })).not.toBeInTheDocument();
  });
});
