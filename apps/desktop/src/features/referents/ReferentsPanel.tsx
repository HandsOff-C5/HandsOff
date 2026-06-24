import type {
  ActionStep,
  PointingEvidence,
  ResolvedIntent,
  SurfaceSnapshot,
} from "@handsoff/contracts";

import { EmptyPanel } from "../../components/EmptyPanel";

function pct(confidence: number): string {
  return `${Math.round(confidence * 100)}%`;
}

function EvidenceItem({ evidence }: { evidence: PointingEvidence }) {
  return (
    <li className="referents-panel__evidence-item">
      <span className="referents-panel__evidence-source">{evidence.source}</span>
      <span className="referents-panel__evidence-confidence">{pct(evidence.confidence)}</span>
      <span className="referents-panel__evidence-strategy">{evidence.strategy}</span>
      {evidence.surface && (
        <span className="referents-panel__evidence-surface">
          {evidence.surface.app} {evidence.surface.id}
        </span>
      )}
      {evidence.cursor && (
        <span className="referents-panel__evidence-cursor">
          {evidence.cursor.x},{evidence.cursor.y}
        </span>
      )}
    </li>
  );
}

function SurfaceCandidateItem({ surface }: { surface: SurfaceSnapshot }) {
  return (
    <li className="referents-panel__surface-item">
      <span className="referents-panel__surface-app">{surface.app}</span>
      <span className="referents-panel__surface-id">{surface.id}</span>
      {surface.title && <span className="referents-panel__surface-title">{surface.title}</span>}
    </li>
  );
}

function ActionStepItem({ step }: { step: ActionStep }) {
  return (
    <li className="referents-panel__action-step">
      <span className="referents-panel__action-step-kind">{step.kind}</span>
      {": "}
      <span className="referents-panel__action-step-label">{step.label}</span>
    </li>
  );
}

export function ReferentsPanel({ intent }: { intent: ResolvedIntent | null }) {
  if (!intent) {
    return <EmptyPanel title="Referents" message="No referent captured yet." />;
  }

  const { input } = intent;
  const evidence = input.pointingEvidence;
  const transcript = input.speech.finalTranscript;
  const isReady = intent.status === "ready";
  const referent = isReady ? intent.referent : null;

  return (
    <section className="panel referents-panel">
      <h2 className="panel__title">Referents</h2>

      {/* Transcript */}
      <div className="referents-panel__transcript">
        <h3 className="referents-panel__section-heading">Transcript</h3>
        <p className="referents-panel__transcript-text">{transcript.text}</p>
        <p className="referents-panel__transcript-meta">
          confidence: {pct(transcript.confidence)} &mdash; latency: {transcript.latencyMs}ms
        </p>
      </div>

      {/* Pointing evidence */}
      {evidence.length > 0 && (
        <div className="referents-panel__evidence">
          <h3 className="referents-panel__section-heading">Pointing Evidence</h3>
          <ul className="referents-panel__evidence-list">
            {evidence.map((item, index) => (
              <EvidenceItem key={`${item.source}-${index}`} evidence={item} />
            ))}
          </ul>
        </div>
      )}

      {/* Surface candidates */}
      {input.surfaceCandidates.length > 0 && (
        <div className="referents-panel__surfaces">
          <h3 className="referents-panel__section-heading">Surface Candidates</h3>
          <ul className="referents-panel__surface-list">
            {input.surfaceCandidates.map((surface) => (
              <SurfaceCandidateItem key={surface.id} surface={surface} />
            ))}
          </ul>
        </div>
      )}

      {/* Intent result */}
      <div className="referents-panel__intent-result">
        <h3 className="referents-panel__section-heading">Intent Result</h3>
        <dl className="referents-panel__intent-details">
          <dt>Status</dt>
          <dd className="referents-panel__intent-status">{intent.status}</dd>

          {"intent_type" in intent && intent.intent_type && (
            <>
              <dt>Intent type</dt>
              <dd className="referents-panel__intent-type">{intent.intent_type}</dd>
            </>
          )}

          {isReady && (
            <>
              <dt>Risk level</dt>
              <dd className="referents-panel__risk-level">{intent.risk_level}</dd>
              <dt>Requires approval</dt>
              <dd className="referents-panel__requires-approval">
                {intent.requires_approval ? "yes" : "no"}
              </dd>
            </>
          )}

          {!isReady && "risk_level" in intent && intent.risk_level && (
            <>
              <dt>Risk level</dt>
              <dd className="referents-panel__risk-level">{intent.risk_level}</dd>
            </>
          )}

          {!isReady && (
            <>
              <dt>Requires approval</dt>
              <dd className="referents-panel__requires-approval">
                {intent.requires_approval ? "yes" : "no"}
              </dd>
              {"reason" in intent && (
                <>
                  <dt>Reason</dt>
                  <dd className="referents-panel__reason">{intent.reason}</dd>
                </>
              )}
              {"summary" in intent && (
                <>
                  <dt>Summary</dt>
                  <dd className="referents-panel__summary">{intent.summary}</dd>
                </>
              )}
            </>
          )}
        </dl>
      </div>

      {/* Selected referent */}
      <div className="referents-panel__selected">
        <h3 className="referents-panel__section-heading">Selected:</h3>
        {referent ? (
          <p className="referents-panel__selected-referent">
            {referent.id} &mdash; {referent.source} &mdash; {pct(referent.confidence)}
          </p>
        ) : (
          <p className="referents-panel__selected-none">No referent selected.</p>
        )}
      </div>

      {/* Action plan */}
      {isReady && intent.action_plan.action_plan.length > 0 && (
        <div className="referents-panel__action-plan">
          <h3 className="referents-panel__section-heading">Action Plan</h3>
          <p className="referents-panel__action-plan-summary">{intent.action_plan.summary}</p>
          <ol className="referents-panel__action-plan-steps">
            {intent.action_plan.action_plan.map((step) => (
              <ActionStepItem key={step.id} step={step} />
            ))}
          </ol>
        </div>
      )}
    </section>
  );
}
