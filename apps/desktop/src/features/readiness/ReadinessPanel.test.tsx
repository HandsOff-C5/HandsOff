import type { CapabilityReadiness } from "@handsoff/contracts";
import { buildReadinessReport } from "@handsoff/desktop";
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { ReadinessPanel } from "./ReadinessPanel";

// A report with at least one of each readiness level — this is the "demo with a
// simulated missing capability" the issue's test/demo proof calls for:
// Accessibility is denied (red) while others are granted/running (green) and one
// is unrequested (yellow).
const SIMULATED: CapabilityReadiness[] = buildReadinessReport({
  capabilities: [
    { id: "camera", kind: "permission", state: "granted" },
    { id: "microphone", kind: "permission", state: "not-determined" },
    { id: "accessibility", kind: "permission", state: "denied" },
    { id: "screen-recording", kind: "permission", state: "granted" },
    { id: "cua", kind: "daemon", state: "running" },
  ],
});

describe("ReadinessPanel", () => {
  it("renders without crashing under the Readiness heading", () => {
    expect(() => render(<ReadinessPanel report={SIMULATED} />)).not.toThrow();
    expect(screen.getByRole("heading", { level: 2, name: "Readiness" })).toBeInTheDocument();
  });

  it("shows a row for every capability", () => {
    render(<ReadinessPanel report={SIMULATED} />);
    for (const label of [
      "Camera",
      "Microphone",
      "Computer-use agent",
      "Accessibility",
      "Screen Recording",
    ]) {
      expect(screen.getByText(label)).toBeInTheDocument();
    }
  });

  it("shows green, yellow, and red statuses for the simulated capabilities", () => {
    const { container } = render(<ReadinessPanel report={SIMULATED} />);
    expect(container.querySelectorAll('[data-readiness="green"]').length).toBeGreaterThan(0);
    expect(container.querySelectorAll('[data-readiness="yellow"]').length).toBeGreaterThan(0);
    expect(container.querySelectorAll('[data-readiness="red"]').length).toBeGreaterThan(0);
  });

  it("surfaces next-action guidance for a blocked capability", () => {
    render(<ReadinessPanel report={SIMULATED} />);
    // Accessibility denied → blocked → carries a next-action hint.
    expect(screen.getByText(/Privacy & Security/)).toBeInTheDocument();
  });

  it("falls back to an all-unknown report when no probe backend is present", () => {
    // No `report` prop and no Tauri runtime (jsdom): every capability shows its
    // unknown/attention state rather than crashing or blanking.
    render(<ReadinessPanel />);
    expect(screen.getAllByText("Not checked yet").length).toBeGreaterThan(0);
  });
});
