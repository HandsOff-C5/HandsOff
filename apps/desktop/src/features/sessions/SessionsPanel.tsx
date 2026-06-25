import type { CuaActionResult, SupervisionAuditEvent } from "@handsoff/contracts";
import { summarizeCuaFailure } from "@handsoff/cua";
import type { SupervisionSession } from "@handsoff/supervision";

import { EmptyPanel } from "../../components/EmptyPanel";

function actionResultSummary(result: CuaActionResult): string {
  if (result.status === "succeeded") return result.summary;
  return (
    summarizeCuaFailure(result) ?? (result.status === "blocked" ? result.reason : result.error)
  );
}

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
    return `CUA ${event.request.kind}: ${actionResultSummary(event.result)}`;
  }
  if (event.kind === "tool_call") {
    // Per-call Intention Log line (U3): tool · approval state · result.
    const gate = event.approval === "auto" ? "auto" : event.approval;
    return `Tool ${event.tool} [${gate}]: ${actionResultSummary(event.result)}`;
  }
  if (event.kind === "execution_finished") {
    const detail = event.result ? `: ${actionResultSummary(event.result)}` : "";
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
