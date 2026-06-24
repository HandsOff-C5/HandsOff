import type { SupervisionAuditEvent } from "@handsoff/contracts";
import type { SupervisionSession } from "@handsoff/supervision";

import { EmptyPanel } from "../../components/EmptyPanel";

function eventSummary(event: SupervisionAuditEvent): string {
  if (event.kind === "intent_created") {
    return event.intent.status === "ready"
      ? `Plan ready: ${event.intent.action_plan.summary}`
      : `Blocked: ${event.intent.reason}`;
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

const MAX_HISTORY = 10;

export function SessionsPanel({
  sessions = [],
  session,
  auditEvents = [],
}: {
  /** Full session history (last {@link MAX_HISTORY} shown). When provided, overrides the legacy `session` prop. */
  sessions?: readonly SupervisionSession[];
  /** @deprecated Pass `sessions` instead. Kept for backward-compat with single-session callers. */
  session?: SupervisionSession | null;
  auditEvents?: readonly SupervisionAuditEvent[];
}) {
  // Normalise: if the caller uses the legacy single-session prop, wrap it in an array.
  const allSessions: readonly SupervisionSession[] =
    sessions.length > 0 ? sessions : session ? [session] : [];

  if (allSessions.length === 0) {
    return (
      <EmptyPanel
        title="Sessions"
        message="No agent sessions yet. Session cards appear once supervision lands."
      />
    );
  }

  const visibleSessions = allSessions.slice(-MAX_HISTORY);

  return (
    <section className="panel sessions">
      <h2 className="panel__title">Sessions</h2>
      <div className="sessions__history" style={{ overflowY: "auto", maxHeight: "400px" }}>
        {[...visibleSessions].reverse().map((s) => (
          <div key={s.id} className="sessions__card">
            <p className="sessions__status">
              <span className="sessions__id">{s.id}</span>{" "}
              <span className="sessions__session-status">{s.status}</span>
            </p>
            {auditEvents.length > 0 && (
              <ol className="sessions__events">
                {auditEvents
                  .filter((e) => e.sessionId === s.id)
                  .slice(-6)
                  .map((event, index) => (
                    <li key={`${event.kind}-${event.recordedAt}-${index}`}>
                      {eventSummary(event)}
                    </li>
                  ))}
              </ol>
            )}
          </div>
        ))}
      </div>
    </section>
  );
}
