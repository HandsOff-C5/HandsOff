import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import type { SupervisionAuditEvent } from "@handsoff/contracts";
import { SessionsPanel } from "./SessionsPanel";

describe("SessionsPanel", () => {
  it("shows recent audit events with blocked reasons", () => {
    const auditEvents: SupervisionAuditEvent[] = [
      {
        kind: "execution_finished",
        sessionId: "session-1",
        actionId: "plan-1",
        recordedAt: "2026-06-22T12:00:00.000Z",
        status: "blocked",
        result: { status: "blocked", reason: "No accessible CUA window was found" },
      },
    ];

    render(
      <SessionsPanel
        session={{
          id: "session-1",
          status: "blocked",
          startedAt: "2026-06-22T12:00:00.000Z",
          updatedAt: "2026-06-22T12:00:00.000Z",
        }}
        auditEvents={auditEvents}
      />,
    );

    expect(
      screen.getByText("Finished: blocked: No accessible CUA window was found"),
    ).toBeInTheDocument();
  });

  it("summarizes a CUA agent action with its status and detail", () => {
    const auditEvents: SupervisionAuditEvent[] = [
      {
        kind: "cua_agent_action",
        sessionId: "session-1",
        actionId: "plan-1",
        stepId: "cua-step-1",
        recordedAt: "2026-06-22T12:00:00.000Z",
        action: { kind: "type_text", elementIndex: 0, text: "secret" },
        risk: "mutating",
        status: "blocked",
        detail: "pending approval",
      },
    ];

    render(
      <SessionsPanel
        session={{
          id: "session-1",
          status: "running",
          startedAt: "2026-06-22T12:00:00.000Z",
          updatedAt: "2026-06-22T12:00:00.000Z",
        }}
        auditEvents={auditEvents}
      />,
    );

    expect(screen.getByText("CUA type_text: blocked — pending approval")).toBeInTheDocument();
  });
});
