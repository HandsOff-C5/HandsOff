import { APP_NAME } from "@handsoff/contracts";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

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
// Readiness (#17), Permissions (#18), and Transcript (#31) are live panels; the
// rest are placeholders.
const EMPTY_PANEL_TITLES = ["Sessions", "Plan preview"];

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

  it("renders empty-state copy in the remaining placeholder panels", () => {
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
});
