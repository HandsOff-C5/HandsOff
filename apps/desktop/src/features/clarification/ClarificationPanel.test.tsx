import type { ClarificationRequest } from "@handsoff/contracts";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { ClarificationPanel } from "./ClarificationPanel";

const ambiguous: ClarificationRequest = {
  reason: "ambiguous",
  question: "Which target did you mean?",
  options: [
    { targetId: "win-1", label: "Slack — #general", confidence: 0.72 },
    { targetId: "win-2", label: "Chrome — GitHub #88", confidence: 0.65 },
  ],
};

describe("ClarificationPanel", () => {
  it("shows an empty state when there is no request", () => {
    render(<ClarificationPanel request={null} />);
    expect(screen.getByText(/no clarification/i)).toBeInTheDocument();
  });

  it("renders the question and each option with its calibrated confidence", () => {
    render(<ClarificationPanel request={ambiguous} />);
    expect(screen.getByText("Which target did you mean?")).toBeInTheDocument();
    expect(screen.getByText("Slack — #general")).toBeInTheDocument();
    expect(screen.getByText("Chrome — GitHub #88")).toBeInTheDocument();
    expect(screen.getByText("72%")).toBeInTheDocument();
    expect(screen.getByText("65%")).toBeInTheDocument();
  });

  it("fires onPick with the chosen targetId", () => {
    const onPick = vi.fn();
    render(<ClarificationPanel request={ambiguous} onPick={onPick} />);
    const [firstPick] = screen.getAllByRole("button", { name: "Pick" });
    if (!firstPick) throw new Error("expected a Pick button");
    fireEvent.click(firstPick);
    expect(onPick).toHaveBeenCalledWith("win-1");
  });

  it("fires onCancel", () => {
    const onCancel = vi.fn();
    render(<ClarificationPanel request={ambiguous} onCancel={onCancel} />);
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(onCancel).toHaveBeenCalledOnce();
  });

  it("renders no Pick buttons for a no_target request", () => {
    const noTarget: ClarificationRequest = {
      reason: "no_target",
      question: "No target found where you pointed — re-point and try again.",
      options: [],
    };
    render(<ClarificationPanel request={noTarget} />);
    expect(screen.getByText(/no target found/i)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Pick" })).not.toBeInTheDocument();
  });

  it("is display-only when no handlers are provided (Pick/Cancel hidden)", () => {
    render(<ClarificationPanel request={ambiguous} />);
    expect(screen.getByText("Slack — #general")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Pick" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Cancel" })).not.toBeInTheDocument();
  });
});
