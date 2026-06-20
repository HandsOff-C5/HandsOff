import { safeParseSurfaceSelectionRecord } from "@handsoff/contracts";
import type { SurfaceSelectionRecord } from "@handsoff/contracts";

// In-memory audit store for context selections (#23). It holds the "select
// context" step of the core loop so the supervision dashboard can replay which
// surface a user pointed at, and tie that to the session/action that used it.
//
// Records are validated at the boundary and kept in insertion order. State is
// updated immutably (a new array per write), and reads hand back the validated,
// normalized records the contract produced. A durable (Tauri/disk) backend can
// implement the same interface later — callers depend on SelectionAuditStore,
// not this implementation.
export interface SelectionAuditStore {
  // Validate and persist a selection record; returns the stored record. Throws
  // if the record fails contract validation.
  record(record: SurfaceSelectionRecord): SurfaceSelectionRecord;
  // Every record, in the order it was recorded.
  list(): readonly SurfaceSelectionRecord[];
  // Records made within one supervision session.
  forSession(sessionId: string): readonly SurfaceSelectionRecord[];
  // Records consumed by one action.
  forAction(actionId: string): readonly SurfaceSelectionRecord[];
}

export function createSelectionAuditStore(): SelectionAuditStore {
  let records: readonly SurfaceSelectionRecord[] = [];

  return {
    record(record) {
      const parsed = safeParseSurfaceSelectionRecord(record);
      if (!parsed.success) {
        throw new Error(`Invalid surface selection record: ${parsed.error.message}`);
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
