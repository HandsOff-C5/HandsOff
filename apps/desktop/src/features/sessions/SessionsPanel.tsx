import type { ExecutionStatus } from "@handsoff/contracts";

import { EmptyPanel } from "../../components/EmptyPanel";

export function SessionsPanel({ status }: { status?: ExecutionStatus | null }) {
  if (!status) {
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
      <p className="sessions__status">Last run: {status}</p>
    </section>
  );
}
