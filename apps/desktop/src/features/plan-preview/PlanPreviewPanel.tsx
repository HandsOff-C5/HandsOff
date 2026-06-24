import type { PlanRunResult } from "@handsoff/actions";
import type { ResolvedIntent } from "@handsoff/contracts";

import { EmptyPanel } from "../../components/EmptyPanel";

type PlanPreviewPanelProps = {
  intent?: ResolvedIntent | null;
  runResult?: PlanRunResult | null;
  onApprove?: () => void;
  onReject?: () => void;
};

function runSummary(runResult: PlanRunResult): string {
  if (runResult.result?.status === "blocked")
    return `${runResult.status}: ${runResult.result.reason}`;
  if (runResult.result?.status === "failed")
    return `${runResult.status}: ${runResult.result.error}`;
  return runResult.status;
}

function targetTitle(intent: Extract<ResolvedIntent, { status: "ready" }>): string {
  const steps = intent.action_plan.action_plan;
  const targeted = steps.find((step) => "target" in step);
  if (targeted && "target" in targeted) return targeted.target.surface.title;
  const launch = steps.find((step) => step.kind === "launch_app");
  if (launch?.kind === "launch_app") return launch.appName;
  return intent.referent?.id ?? intent.action_plan.summary;
}

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

  if (intent.status === "satisfied") {
    return (
      <section className="panel plan-preview">
        <h2 className="panel__title">Plan preview</h2>
        <p className="plan-preview__status" role="status">
          {intent.summary}
        </p>
      </section>
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
          <dd>{targetTitle(intent)}</dd>
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
          {runSummary(runResult)}
        </p>
      ) : null}
      {intent.requires_approval && !runResult ? (
        // Mutating/destructive plans gate on explicit approval. Read-only and
        // reversible plans (requires_approval === false) auto-run in the
        // controller, so they never wait for a manual trigger here.
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
