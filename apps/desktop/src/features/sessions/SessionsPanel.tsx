import type { SupervisionSession } from "@handsoff/supervision";

import { EmptyPanel } from "../../components/EmptyPanel";

export function SessionsPanel({ session }: { session?: SupervisionSession | null }) {
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
    </section>
  );
}
