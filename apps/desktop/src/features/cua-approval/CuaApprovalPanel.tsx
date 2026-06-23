import type { PendingApproval } from "@handsoff/cua";

import { EmptyPanel } from "../../components/EmptyPanel";

type CuaApprovalPanelProps = {
  pending?: readonly PendingApproval[];
  onApprove?: (id: string) => void;
  onDeny?: (id: string) => void;
};

// The human-in-the-loop UI for the computer-use gate (CUA-3). The agent loop
// parks every mutating/destructive action here (it auto-runs read-only and
// reversible ones); the operator approves or denies each before the driver
// touches the screen. Presentational: state lives in the ApprovalController,
// bridged in by useCuaApproval.
export function CuaApprovalPanel({ pending, onApprove, onDeny }: CuaApprovalPanelProps) {
  if (!pending || pending.length === 0) {
    return (
      <EmptyPanel
        title="Agent approval"
        message="No actions awaiting approval. The agent pauses here before any action that changes your screen."
      />
    );
  }

  return (
    <section className="panel cua-approval">
      <h2 className="panel__title">Agent approval</h2>
      <ul className="cua-approval__queue">
        {pending.map((request) => (
          <li key={request.id} className="cua-approval__item">
            <span className="cua-approval__action">{request.action.action}</span>
            <span className="cua-approval__risk" data-risk={request.risk}>
              {request.risk}
            </span>
            <div className="cua-approval__actions">
              {onApprove ? (
                <button type="button" onClick={() => onApprove(request.id)}>
                  Approve
                </button>
              ) : null}
              {onDeny ? (
                <button type="button" onClick={() => onDeny(request.id)}>
                  Deny
                </button>
              ) : null}
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
