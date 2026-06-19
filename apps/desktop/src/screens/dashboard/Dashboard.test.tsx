import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { App } from "../../App";
import { Dashboard } from "./Dashboard";

const PANEL_TITLES = ["Readiness", "Surfaces", "Sessions", "Plan preview"];

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

  it("renders empty-state copy in every panel", () => {
    render(<Dashboard />);
    expect(screen.getAllByText(/yet\./i)).toHaveLength(PANEL_TITLES.length);
  });

  it("composes the dashboard into the app shell", () => {
    expect(() => render(<App />)).not.toThrow();
    expect(screen.getByRole("heading", { level: 1, name: /handsoff/i })).toBeInTheDocument();
  });
});
