import type { ComputerAction, RiskLevel } from "@handsoff/contracts";
import { describe, expect, it, vi } from "vitest";

import type { RunComputerUseLoopArgs } from "../runner/computer-use-loop";
import type { ApprovalController, PendingApproval } from "./approval-controller";
import { createApprovalController } from "./approval-controller";

const clickEntry: { action: ComputerAction; risk: RiskLevel } = {
  action: { action: "left_click", coordinate: [1, 2] },
  risk: "mutating",
};
const typeEntry: { action: ComputerAction; risk: RiskLevel } = {
  action: { action: "type", text: "hi" },
  risk: "mutating",
};

// noUncheckedIndexedAccess: read the head of the queue with an explicit guard
// so the specs stay typecheck-clean (the pre-commit gate runs tsc, not vitest).
function firstPending(controller: ApprovalController): PendingApproval {
  const [first] = controller.pending();
  if (!first) throw new Error("expected at least one pending approval");
  return first;
}

describe("createApprovalController", () => {
  it("queues a request and resolving it with allow fulfills the promise", async () => {
    const controller = createApprovalController();
    const decision = controller.approve(clickEntry);
    expect(controller.pending()).toHaveLength(1);

    controller.resolve(firstPending(controller).id, "allow");

    await expect(decision).resolves.toBe("allow");
    expect(controller.pending()).toHaveLength(0);
  });

  it("resolving with deny fulfills the promise with deny", async () => {
    const controller = createApprovalController();
    const decision = controller.approve(clickEntry);
    controller.resolve(firstPending(controller).id, "deny");
    await expect(decision).resolves.toBe("deny");
  });

  it("carries the action and risk on the pending request", () => {
    const controller = createApprovalController();
    void controller.approve(clickEntry);
    expect(firstPending(controller)).toMatchObject({
      action: { action: "left_click", coordinate: [1, 2] },
      risk: "mutating",
    });
  });

  it("assigns distinct ids and resolves concurrent requests independently", async () => {
    const controller = createApprovalController();
    const first = controller.approve(clickEntry);
    const second = controller.approve(typeEntry);

    const pending = controller.pending();
    const r1 = pending[0];
    const r2 = pending[1];
    if (!r1 || !r2) throw new Error("expected two pending approvals");
    expect(r1.id).not.toBe(r2.id);

    controller.resolve(r2.id, "deny");
    await expect(second).resolves.toBe("deny");
    expect(controller.pending().map((p) => p.id)).toEqual([r1.id]);

    controller.resolve(r1.id, "allow");
    await expect(first).resolves.toBe("allow");
    expect(controller.pending()).toHaveLength(0);
  });

  it("ignores resolve for an unknown id", () => {
    const controller = createApprovalController();
    void controller.approve(clickEntry);
    expect(() => controller.resolve("nope", "allow")).not.toThrow();
    expect(controller.pending()).toHaveLength(1);
  });

  it("ignores a second resolve for an already-resolved id", async () => {
    const controller = createApprovalController();
    const decision = controller.approve(clickEntry);
    const { id } = firstPending(controller);
    controller.resolve(id, "allow");
    await expect(decision).resolves.toBe("allow");
    expect(() => controller.resolve(id, "deny")).not.toThrow();
  });

  it("notifies subscribers when a request is queued and when it resolves, until unsubscribed", () => {
    const controller = createApprovalController();
    const listener = vi.fn();
    const unsubscribe = controller.subscribe(listener);

    void controller.approve(clickEntry);
    expect(listener).toHaveBeenCalledTimes(1);

    controller.resolve(firstPending(controller).id, "allow");
    expect(listener).toHaveBeenCalledTimes(2);

    unsubscribe();
    void controller.approve(typeEntry);
    expect(listener).toHaveBeenCalledTimes(2);
  });

  it("exposes an approver assignable to the loop's approve port", () => {
    const controller = createApprovalController();
    const approve: NonNullable<RunComputerUseLoopArgs["approve"]> = controller.approve;
    expect(approve).toBe(controller.approve);
  });
});
