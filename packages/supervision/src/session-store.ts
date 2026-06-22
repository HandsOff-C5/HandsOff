import type { ExecutionStatus } from "@handsoff/contracts";

export type TerminalSessionStatus = Exclude<ExecutionStatus, "queued" | "running">;

export type SupervisionSession = {
  id: string;
  status: ExecutionStatus;
  startedAt: string;
  updatedAt: string;
  finishedAt?: string;
};

export type SupervisionSessionStore = {
  start(startedAt: string): SupervisionSession;
  run(id: string, updatedAt: string): SupervisionSession;
  finish(id: string, status: TerminalSessionStatus, finishedAt: string): SupervisionSession;
  list(): readonly SupervisionSession[];
};

export function createSupervisionSessionStore(): SupervisionSessionStore {
  let nextId = 1;
  let sessions: readonly SupervisionSession[] = [];

  function update(id: string, change: (session: SupervisionSession) => SupervisionSession) {
    let updated: SupervisionSession | null = null;
    sessions = sessions.map((session) => {
      if (session.id !== id) return session;
      updated = change(session);
      return updated;
    });
    if (!updated) throw new Error(`Unknown supervision session: ${id}`);
    return updated;
  }

  return {
    start(startedAt) {
      const session: SupervisionSession = {
        id: `session-${nextId}`,
        status: "queued",
        startedAt,
        updatedAt: startedAt,
      };
      nextId += 1;
      sessions = [...sessions, session];
      return session;
    },
    run(id, updatedAt) {
      return update(id, (session) => ({ ...session, status: "running", updatedAt }));
    },
    finish(id, status, finishedAt) {
      return update(id, (session) => ({ ...session, status, updatedAt: finishedAt, finishedAt }));
    },
    list() {
      return [...sessions];
    },
  };
}
