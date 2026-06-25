import { describe, expect, it } from "vitest";

import { gateToolCall } from "./run-approved-plan";

describe("gateToolCall — per-call approval gate (U2)", () => {
  it("allows a read-only tool call without approval", () => {
    const gate = gateToolCall({ tool: "get_window_state" });
    expect(gate).toEqual({ allowed: true, risk: "read_only" });
  });

  it("allows a draft tool call (type_text) without approval", () => {
    const gate = gateToolCall({ tool: "type_text" });
    expect(gate).toEqual({ allowed: true, risk: "reversible" });
  });

  it("allows a navigation click without approval", () => {
    const gate = gateToolCall({
      tool: "click",
      target: { element: { role: "AXPopUpButton", title: "Sort by" } },
    });
    expect(gate).toEqual({ allowed: true, risk: "reversible" });
  });

  it("blocks a commit click (Send) until approved", () => {
    const gate = gateToolCall({
      tool: "click",
      target: { element: { role: "AXButton", title: "Send" } },
    });
    expect(gate).toMatchObject({
      allowed: false,
      risk: "mutating",
      result: { status: "blocked" },
    });
    if (!gate.allowed) {
      expect(gate.result.reason).toContain("Approval required");
      expect(gate.result.reason).toContain("click");
    }
  });

  it("allows a commit click once a matching approval is granted", () => {
    const gate = gateToolCall({
      tool: "click",
      target: { element: { role: "AXButton", title: "Send" } },
      approved: true,
    });
    expect(gate).toEqual({ allowed: true, risk: "mutating" });
  });

  it("blocks a destructive tool (kill_app) until approved", () => {
    expect(gateToolCall({ tool: "kill_app" })).toMatchObject({
      allowed: false,
      risk: "destructive_external",
    });
    expect(gateToolCall({ tool: "kill_app", approved: true })).toEqual({
      allowed: true,
      risk: "destructive_external",
    });
  });

  it("derives the gate from risk — a model that mislabels a Send click cannot bypass it", () => {
    // The model only supplies the tool + target; risk is computed here, never
    // taken from any model-supplied risk/requires_approval claim. A commit click
    // with no granted approval stays blocked regardless of what the model says.
    const gate = gateToolCall({
      tool: "click",
      target: { element: { role: "AXButton", title: "Delete account" } },
      approved: false,
    });
    expect(gate.allowed).toBe(false);
    expect(gate.risk).toBe("mutating");
  });
});
