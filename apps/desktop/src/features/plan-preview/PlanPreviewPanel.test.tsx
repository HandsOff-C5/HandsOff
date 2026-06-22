import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { PlanPreviewPanel } from "./PlanPreviewPanel";
import type { ResolvedIntent } from "@handsoff/contracts";

function intent(overrides: Partial<Extract<ResolvedIntent, { status: "ready" }>> = {}) {
  const surface = {
    id: "surface-1",
    title: "Notes",
    app: "Notes",
    availability: "available" as const,
    accessStatus: "accessible" as const,
  };

  return {
    status: "ready" as const,
    id: "intent-1",
    input: {
      sessionId: "session-1",
      speech: {
        finalTranscript: {
          kind: "final" as const,
          text: "click there",
          confidence: 0.9,
          latencyMs: 100,
          receivedAt: 1,
        },
      },
      pointingEvidence: [
        {
          source: "cursor" as const,
          confidence: 1,
          strategy: "active-window-current-cursor",
          surface,
        },
      ],
      surfaceCandidates: [surface],
    },
    intent_type: "click" as const,
    referent: { id: "surface-1", source: "fusion" as const, confidence: 1 },
    constraints: [],
    risk_level: "mutating" as const,
    requires_approval: true,
    target_agent: "cua-driver" as const,
    action_plan: {
      id: "plan-1",
      summary: "Click selected target",
      risk_level: "mutating" as const,
      requires_approval: true,
      target_agent: "cua-driver" as const,
      action_plan: [
        {
          id: "step-1",
          kind: "click_element" as const,
          label: "Click selected target",
          target: { surface, elementIndex: 0 },
        },
      ],
    },
    createdAt: "2026-06-22T12:00:00.000Z",
    ...overrides,
  };
}

describe("PlanPreviewPanel", () => {
  it("renders transcript, target, risk, and ordered CUA step", () => {
    render(<PlanPreviewPanel intent={intent()} />);

    expect(screen.getByText("click there")).toBeInTheDocument();
    expect(screen.getByText("Notes")).toBeInTheDocument();
    expect(screen.getByText("mutating")).toBeInTheDocument();
    expect(screen.getByText("Click selected target")).toBeInTheDocument();
  });

  it("gates mutating plans behind approval", () => {
    const approve = vi.fn();
    const reject = vi.fn();
    render(<PlanPreviewPanel intent={intent()} onApprove={approve} onReject={reject} />);

    fireEvent.click(screen.getByRole("button", { name: "Approve" }));
    fireEvent.click(screen.getByRole("button", { name: "Reject" }));

    expect(approve).toHaveBeenCalledOnce();
    expect(reject).toHaveBeenCalledOnce();
  });

  it("renders blocked reasons without approval controls", () => {
    render(
      <PlanPreviewPanel
        intent={{
          status: "blocked",
          id: "intent-2",
          input: intent().input,
          constraints: [],
          requires_approval: false,
          target_agent: "none",
          reason: "Unsupported voice command",
          createdAt: "2026-06-22T12:00:00.000Z",
        }}
      />,
    );

    expect(screen.getByText("Unsupported voice command")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Approve" })).not.toBeInTheDocument();
  });
});
