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
      screen.getByText(
        "Finished: blocked: The selected window is not reachable right now. Bring it back on screen or switch to its Space, then point and speak again.",
      ),
    ).toBeInTheDocument();
  });
});
