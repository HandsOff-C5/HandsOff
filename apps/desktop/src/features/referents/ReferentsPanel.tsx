import type { PointingEvidence, ResolvedIntent } from "@handsoff/contracts";

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

export function ReferentsPanel({ intent }: { intent: ResolvedIntent | null }) {
  if (!intent) {
    return <EmptyPanel title="Referents" message="No referent captured yet." />;
  }

  const evidence = intent.input.pointingEvidence;
  const isReady = intent.status === "ready";
  const referent = isReady ? intent.referent : null;

  return (
    <section className="panel referents-panel">
      <h2 className="panel__title">Referents</h2>

      {evidence.length > 0 && (
        <div className="referents-panel__evidence">
          <h3 className="referents-panel__evidence-heading">Pointing Evidence</h3>
          <ul className="referents-panel__evidence-list">
            {evidence.map((item, index) => (
              <EvidenceItem key={`${item.source}-${index}`} evidence={item} />
            ))}
          </ul>
        </div>
      )}

      {isReady && (
        <div className="referents-panel__selected">
          <h3 className="referents-panel__selected-heading">Selected:</h3>
          {referent ? (
            <p className="referents-panel__selected-referent">
              {referent.id} &mdash; {referent.source} &mdash; {pct(referent.confidence)}
            </p>
          ) : (
            <p className="referents-panel__selected-none">No referent selected.</p>
          )}
        </div>
      )}
    </section>
  );
}
