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
    surfaceCandidates: [
      {
        id: "win-7",
        title: "Finder",
        app: "Finder",
        availability: "available",
        accessStatus: "accessible",
      },
    ],
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
    action_plan: [
      {
        id: "step-1",
        kind: "click_element",
        label: "Click submit",
        target: {
          surface: {
            id: "win-7",
            title: "Finder",
            app: "Finder",
            availability: "available",
            accessStatus: "accessible",
          },
        },
      },
    ],
  },
  createdAt: "2026-06-23T10:00:00.000Z",
};

describe("ReferentsPanel", () => {
  it("renders placeholder when intent is null", () => {
    render(<ReferentsPanel intent={null} />);
    expect(screen.getByText("No referent captured yet.")).toBeInTheDocument();
  });

  it("renders transcript text and metadata", () => {
    render(<ReferentsPanel intent={baseReady} />);
    expect(screen.getByText("click that")).toBeInTheDocument();
    expect(screen.getByText(/confidence: 90%/)).toBeInTheDocument();
    expect(screen.getByText(/latency: 100ms/)).toBeInTheDocument();
  });

  it("renders pointing evidence items when intent has evidence", () => {
    render(<ReferentsPanel intent={baseReady} />);
    expect(screen.getByText("cursor")).toBeInTheDocument();
    expect(screen.getByText("85%")).toBeInTheDocument();
    expect(screen.getByText("last-known-position")).toBeInTheDocument();
    expect(screen.getByText("320,240")).toBeInTheDocument();
  });

  it("renders surface candidates", () => {
    render(<ReferentsPanel intent={baseReady} />);
    // app name and id from surfaceCandidates
    const appEls = screen.getAllByText("Finder");
    expect(appEls.length).toBeGreaterThan(0);
    expect(screen.getByText("win-7")).toBeInTheDocument();
  });

  it("renders intent result fields", () => {
    render(<ReferentsPanel intent={baseReady} />);
    expect(screen.getByText("ready")).toBeInTheDocument();
    expect(screen.getByText("click")).toBeInTheDocument();
    expect(screen.getByText("reversible")).toBeInTheDocument();
    // requires_approval = false -> "no"
    const noEls = screen.getAllByText("no");
    expect(noEls.length).toBeGreaterThan(0);
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

  it("renders action plan summary and steps", () => {
    render(<ReferentsPanel intent={baseReady} />);
    expect(screen.getByText("Click the button")).toBeInTheDocument();
    expect(screen.getByText("click_element")).toBeInTheDocument();
    expect(screen.getByText("Click submit")).toBeInTheDocument();
  });

  it("renders blocked intent with reason and no action plan", () => {
    const blocked: ResolvedIntent = {
      status: "blocked",
      id: "intent-2",
      input: {
        sessionId: "session-2",
        speech: {
          finalTranscript: {
            kind: "final",
            text: "do something",
            confidence: 0.75,
            latencyMs: 80,
            receivedAt: 2,
          },
        },
        pointingEvidence: [
          {
            source: "cursor",
            confidence: 0.6,
            strategy: "active-window-current-cursor",
          },
        ],
        surfaceCandidates: [],
      },
      intent_type: "click",
      constraints: [],
      requires_approval: false,
      target_agent: "cua-driver",
      reason: "Ambiguous target — cannot resolve referent",
      createdAt: "2026-06-23T10:01:00.000Z",
    };
    render(<ReferentsPanel intent={blocked} />);
    expect(screen.getByText("do something")).toBeInTheDocument();
    expect(screen.getByText("blocked")).toBeInTheDocument();
    expect(screen.getByText("Ambiguous target — cannot resolve referent")).toBeInTheDocument();
    expect(screen.getByText("No referent selected.")).toBeInTheDocument();
  });
});
