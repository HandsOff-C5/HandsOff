import { safeParseSupervisionAuditEvent } from "@handsoff/contracts";
import type { SupervisionAuditEvent } from "@handsoff/contracts";

export interface ActionAuditStore {
  record(event: SupervisionAuditEvent): SupervisionAuditEvent;
  list(): readonly SupervisionAuditEvent[];
  forSession(sessionId: string): readonly SupervisionAuditEvent[];
  forAction(actionId: string): readonly SupervisionAuditEvent[];
}

export function createActionAuditStore(): ActionAuditStore {
  let records: readonly SupervisionAuditEvent[] = [];

  return {
    record(event) {
      const parsed = safeParseSupervisionAuditEvent(event);
      if (!parsed.success) {
        throw new Error(`Invalid supervision audit event: ${parsed.error.message}`);
      }
      records = [...records, parsed.data];
      return parsed.data;
    },
    list() {
      return [...records];
    },
    forSession(sessionId) {
      return records.filter((entry) => entry.sessionId === sessionId);
    },
    forAction(actionId) {
      return records.filter((entry) => entry.actionId === actionId);
    },
  };
}
