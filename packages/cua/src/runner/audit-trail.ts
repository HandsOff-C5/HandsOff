import type { SupervisionAuditEvent } from "@handsoff/contracts";

import type { LoopEntry } from "./computer-use-loop";

// Turn a computer-use loop transcript into supervision audit events so an agent
// run is replayable in the session trail. Each executed or gate-blocked action
// becomes one `cua_agent_action` event (narration entries carry no audit kind
// and are skipped); steps are numbered over the emitted events. The caller
// supplies the session/action ids and a single recordedAt (matching the planned
// path's audit stamping). Screenshots are intentionally not carried — the event
// schema stores action metadata only (#23).
export function cuaTranscriptToAuditEvents(args: {
  sessionId: string;
  actionId: string;
  recordedAt: string;
  transcript: readonly LoopEntry[];
}): SupervisionAuditEvent[] {
  const events: SupervisionAuditEvent[] = [];

  for (const entry of args.transcript) {
    if (entry.kind === "assistant") continue;

    const stepId = `cua-step-${events.length + 1}`;
    const base = {
      kind: "cua_agent_action" as const,
      sessionId: args.sessionId,
      actionId: args.actionId,
      stepId,
      recordedAt: args.recordedAt,
      action: entry.action,
      risk: entry.risk,
    };

    if (entry.kind === "blocked") {
      events.push({ ...base, status: "blocked", detail: entry.reason });
      continue;
    }

    if (entry.outcome.status === "error") {
      events.push({ ...base, status: "failed", detail: entry.outcome.error });
    } else {
      events.push({ ...base, status: "ran" });
    }
  }

  return events;
}
