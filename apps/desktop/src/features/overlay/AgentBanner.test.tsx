import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { AgentBanner } from "./AgentBanner";

describe("AgentBanner", () => {
  it("renders nothing actionable when the agent is idle", () => {
    const { container } = render(<AgentBanner agent={{ action: null, pendingApproval: false }} />);
    expect(screen.getByText("Idle")).toBeInTheDocument();
    expect(container.querySelector(".agent-banner__chip")).toBeNull();
  });

  it("shows the current action in plain words while acting", () => {
    render(
      <AgentBanner agent={{ action: 'click "Equals" in Calculator', pendingApproval: false }} />,
    );
    expect(screen.getByText('Acting: click "Equals" in Calculator')).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /approve/i })).toBeNull();
  });

  it("offers an approve/deny chip when a step is pending and routes the clicks", () => {
    const onApprove = vi.fn();
    const onDeny = vi.fn();
    render(
      <AgentBanner
        agent={{ action: "delete the file", pendingApproval: true }}
        onApprove={onApprove}
        onDeny={onDeny}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /approve/i }));
    fireEvent.click(screen.getByRole("button", { name: /deny/i }));
    expect(onApprove).toHaveBeenCalledTimes(1);
    expect(onDeny).toHaveBeenCalledTimes(1);
  });
});
