import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { App } from "../../App";
import { Dashboard } from "./Dashboard";

const PANEL_TITLES = ["Readiness", "Settings", "Sessions", "Plan preview"];
// Readiness is now a live panel (issue #17); the rest are still placeholders.
const EMPTY_PANEL_TITLES = ["Sessions", "Plan preview"];

describe("Dashboard", () => {
  it("mounts without crashing", () => {
    expect(() => render(<Dashboard />)).not.toThrow();
  });

  it("shows the HandsOff brand in the header", () => {
    render(<Dashboard />);
    expect(screen.getByRole("heading", { level: 1, name: /handsoff/i })).toBeInTheDocument();
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
    expect(screen.getByText("Accessibility")).toBeInTheDocument();
    expect(screen.getByText("Computer-use agent")).toBeInTheDocument();
  });

  it("composes the dashboard into the app shell", () => {
    expect(() => render(<App />)).not.toThrow();
    expect(screen.getByRole("heading", { level: 1, name: /handsoff/i })).toBeInTheDocument();
  });
});
