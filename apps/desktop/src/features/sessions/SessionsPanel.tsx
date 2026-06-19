import { EmptyPanel } from "../../components/EmptyPanel";

// Placeholder. Agent session cards (planned, waiting-approval, running, blocked,
// complete, failed) land with the supervision lane.
export function SessionsPanel() {
  return (
    <EmptyPanel
      title="Sessions"
      message="No agent sessions yet. Session cards appear once supervision lands."
    />
  );
}
