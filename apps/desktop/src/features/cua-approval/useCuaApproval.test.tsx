import type { ComputerAction, RiskLevel } from "@handsoff/contracts";
import { createApprovalController } from "@handsoff/cua";
import { act, renderHook } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { useCuaApproval } from "./useCuaApproval";

const clickEntry: { action: ComputerAction; risk: RiskLevel } = {
  action: { action: "left_click", coordinate: [1, 2] },
  risk: "mutating",
};

describe("useCuaApproval", () => {
  it("starts with no pending approvals", () => {
    const controller = createApprovalController();
    const { result } = renderHook(() => useCuaApproval(controller));
    expect(result.current.pending).toHaveLength(0);
  });

  it("re-renders with the queued approval when the controller receives one", () => {
    const controller = createApprovalController();
    const { result } = renderHook(() => useCuaApproval(controller));
    act(() => {
      void controller.approve(clickEntry);
    });
    expect(result.current.pending).toHaveLength(1);
    expect(result.current.pending[0]?.action.action).toBe("left_click");
  });

  it("decide(id, allow) resolves the loop's awaited promise and clears the queue", async () => {
    const controller = createApprovalController();
    const { result } = renderHook(() => useCuaApproval(controller));
    let decision: Promise<unknown> = Promise.resolve();
    act(() => {
      decision = controller.approve(clickEntry);
    });
    const id = result.current.pending[0]?.id;
    if (!id) throw new Error("expected a pending approval");
    act(() => {
      result.current.decide(id, "allow");
    });
    await expect(decision).resolves.toBe("allow");
    expect(result.current.pending).toHaveLength(0);
  });

  it("stops re-rendering after unmount", () => {
    const controller = createApprovalController();
    const { result, unmount } = renderHook(() => useCuaApproval(controller));
    unmount();
    act(() => {
      void controller.approve(clickEntry);
    });
    expect(result.current.pending).toHaveLength(0);
  });
});
