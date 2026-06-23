import type { PlanRunResult } from "@handsoff/actions";
import type { ResolvedIntent } from "@handsoff/contracts";

import { EmptyPanel } from "../../components/EmptyPanel";

type PlanPreviewPanelProps = {
  intent?: ResolvedIntent | null;
  runResult?: PlanRunResult | null;
  onApprove?: () => void;
  onReject?: () => void;
};

export function PlanPreviewPanel({
  intent,
  runResult,
  onApprove,
  onReject,
}: PlanPreviewPanelProps) {
  if (!intent) {
    return (
      <EmptyPanel
        title="Plan preview"
        message="No plan to preview yet. Proposed plans show here before you approve them."
      />
    );
  }

  if (intent.status !== "ready") {
    return (
      <section className="panel plan-preview">
        <h2 className="panel__title">Plan preview</h2>
        <p className="plan-preview__blocked">{intent.reason}</p>
      </section>
    );
  }

  return (
    <section className="panel plan-preview">
      <h2 className="panel__title">Plan preview</h2>
      <dl className="plan-preview__facts">
        <div>
          <dt>Transcript</dt>
          <dd>{intent.input.speech.finalTranscript.text}</dd>
        </div>
        <div>
          <dt>Target</dt>
          <dd>{intent.action_plan.action_plan[0]?.target.surface.title ?? intent.referent.id}</dd>
        </div>
        <div>
          <dt>Risk</dt>
          <dd>{intent.risk_level}</dd>
        </div>
      </dl>
      <ol className="plan-preview__steps">
        {intent.action_plan.action_plan.map((step) => (
          <li key={step.id}>{step.label}</li>
        ))}
      </ol>
      {runResult ? (
        <p className="plan-preview__status" role="status">
          {runResult.status}
        </p>
      ) : null}
      {intent.requires_approval && !runResult ? (
        <div className="plan-preview__actions">
          <button type="button" onClick={onApprove}>
            Approve
          </button>
          <button type="button" onClick={onReject}>
            Reject
          </button>
        </div>
      ) : null}
    </section>
  );
}
