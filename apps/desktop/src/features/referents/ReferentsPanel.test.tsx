import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import type { ResolvedIntent } from "@handsoff/contracts";
import { ReferentsPanel } from "./ReferentsPanel";

const baseReady: ResolvedIntent = {
  status: "ready",
  id: "intent-1",
  input: {
    sessionId: "session-1",
    speech: {
      finalTranscript: {
        kind: "final",
        text: "click that",
        confidence: 0.9,
        latencyMs: 100,
        receivedAt: 1,
      },
    },
    pointingEvidence: [
      {
        source: "cursor",
        confidence: 0.85,
        strategy: "last-known-position",
        cursor: { x: 320, y: 240 },
      },
    ],
    surfaceCandidates: [],
  },
  intent_type: "click",
  referent: {
    id: "window-42",
    source: "gesture",
    confidence: 0.91,
  },
  constraints: [],
  risk_level: "reversible",
  requires_approval: false,
  target_agent: "cua-driver",
  action_plan: {
    id: "plan-1",
    summary: "Click the button",
    risk_level: "reversible",
    requires_approval: false,
    target_agent: "cua-driver",
    action_plan: [],
  },
  createdAt: "2026-06-23T10:00:00.000Z",
};

describe("ReferentsPanel", () => {
  it("renders placeholder when intent is null", () => {
    render(<ReferentsPanel intent={null} />);
    expect(screen.getByText("No referent captured yet.")).toBeInTheDocument();
  });

  it("renders pointing evidence items when intent has evidence", () => {
    render(<ReferentsPanel intent={baseReady} />);
    expect(screen.getByText("cursor")).toBeInTheDocument();
    expect(screen.getByText("85%")).toBeInTheDocument();
    expect(screen.getByText("last-known-position")).toBeInTheDocument();
    expect(screen.getByText("320,240")).toBeInTheDocument();
  });

  it("shows selected referent line when status=ready and referent non-null", () => {
    render(<ReferentsPanel intent={baseReady} />);
    expect(screen.getByText("Selected:")).toBeInTheDocument();
    expect(screen.getByText(/window-42/)).toBeInTheDocument();
    expect(screen.getByText(/gesture/)).toBeInTheDocument();
    expect(screen.getByText(/91%/)).toBeInTheDocument();
  });

  it("shows no-selected-referent fallback when status=ready but referent is null", () => {
    const intentWithNullReferent: ResolvedIntent = {
      ...baseReady,
      referent: null,
    };
    render(<ReferentsPanel intent={intentWithNullReferent} />);
    expect(screen.getByText("Selected:")).toBeInTheDocument();
    expect(screen.getByText("No referent selected.")).toBeInTheDocument();
  });
});
