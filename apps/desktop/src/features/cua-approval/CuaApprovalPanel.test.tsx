import type { PendingApproval } from "@handsoff/cua";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { CuaApprovalPanel } from "./CuaApprovalPanel";

const clickPending: PendingApproval = {
  id: "approval-1",
  action: { kind: "click", elementIndex: 10 },
  risk: "mutating",
};

describe("CuaApprovalPanel", () => {
  it("shows an empty state when nothing is awaiting approval", () => {
    render(<CuaApprovalPanel pending={[]} />);
    expect(screen.getByText(/no actions? awaiting approval/i)).toBeInTheDocument();
  });

  it("renders the pending action verb and its risk", () => {
    render(<CuaApprovalPanel pending={[clickPending]} />);
    expect(screen.getByText(/click/)).toBeInTheDocument();
    expect(screen.getByText(/mutating/)).toBeInTheDocument();
  });

  it("fires onApprove with the request id when Approve is clicked", () => {
    const onApprove = vi.fn();
    render(<CuaApprovalPanel pending={[clickPending]} onApprove={onApprove} />);
    fireEvent.click(screen.getByRole("button", { name: /approve/i }));
    expect(onApprove).toHaveBeenCalledWith("approval-1");
  });

  it("fires onDeny with the request id when Deny is clicked", () => {
    const onDeny = vi.fn();
    render(<CuaApprovalPanel pending={[clickPending]} onDeny={onDeny} />);
    fireEvent.click(screen.getByRole("button", { name: /deny/i }));
    expect(onDeny).toHaveBeenCalledWith("approval-1");
  });
});
