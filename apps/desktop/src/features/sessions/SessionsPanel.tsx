import type { SupervisionAuditEvent } from "@handsoff/contracts";
import type { SupervisionSession } from "@handsoff/supervision";

import { EmptyPanel } from "../../components/EmptyPanel";

function eventSummary(event: SupervisionAuditEvent): string {
  if (event.kind === "intent_created") {
    if (event.intent.status === "ready") return `Plan ready: ${event.intent.action_plan.summary}`;
    if (event.intent.status === "satisfied") return `Satisfied: ${event.intent.summary}`;
    return `Blocked: ${event.intent.reason}`;
  }
  if (event.kind === "approval_decided") {
    return `Approval ${event.approval.decision}`;
  }
  if (event.kind === "cua_call") {
    const result =
      event.result.status === "succeeded"
        ? event.result.summary
        : event.result.status === "blocked"
          ? event.result.reason
          : event.result.error;
    return `CUA ${event.request.kind}: ${result}`;
  }
  if (event.kind === "execution_finished") {
    const detail =
      event.result?.status === "blocked"
        ? `: ${event.result.reason}`
        : event.result?.status === "failed"
          ? `: ${event.result.error}`
          : "";
    return `Finished: ${event.status}${detail}`;
  }
  return `${event.phase === "pre" ? "Before" : "After"} state captured`;
}

export function SessionsPanel({
  session,
  auditEvents = [],
}: {
  session?: SupervisionSession | null;
  auditEvents?: readonly SupervisionAuditEvent[];
}) {
  if (!session) {
    return (
      <EmptyPanel
        title="Sessions"
        message="No agent sessions yet. Session cards appear once supervision lands."
      />
    );
  }

  return (
    <section className="panel sessions">
      <h2 className="panel__title">Sessions</h2>
      <p className="sessions__status">Session: {session.id}</p>
      <p className="sessions__status">Last run: {session.status}</p>
      {auditEvents.length > 0 && (
        <ol className="sessions__events">
          {auditEvents.slice(-6).map((event, index) => (
            <li key={`${event.kind}-${event.recordedAt}-${index}`}>{eventSummary(event)}</li>
          ))}
        </ol>
      )}
    </section>
  );
}
