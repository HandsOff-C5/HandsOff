import type { EvidenceFusion, FusionDecisionKind } from "@handsoff/intent";

type FusionHudProps = {
  // The current fusion breakdown to display; null/undefined renders the idle HUD.
  fusion?: EvidenceFusion | null;
};

const DECISION_LABEL: Record<FusionDecisionKind, string> = {
  act: "Acting",
  clarify_low_confidence: "Clarify — low confidence",
  clarify_ambiguous: "Clarify — ambiguous",
  no_target: "No target",
};

const pct = (value: number): string => `${Math.round(value * 100)}%`;

// The multimodal HUD drawn on the transparent overlay window (one per display).
// It makes "garbage in, garbage out" visible: a meter per fused target (with the
// per-channel votes that built it), the winner being acted on, and — when a
// channel pulls against the consensus — the DRAG line naming it, so the operator
// knows which model to adjust to reduce the noise.
export function FusionHud({ fusion }: FusionHudProps) {
  if (!fusion || fusion.targets.length === 0) {
    return (
      <section className="fusion-hud fusion-hud--idle" aria-label="Fusion HUD">
        <p className="fusion-hud__idle">No signal</p>
      </section>
    );
  }

  return (
    <section className="fusion-hud" aria-label="Fusion HUD">
      <header className="fusion-hud__head">
        <span
          data-testid="fusion-decision"
          className="fusion-hud__decision"
          data-decision={fusion.decision}
        >
          {DECISION_LABEL[fusion.decision]}
        </span>
      </header>

      <ul className="fusion-hud__targets">
        {fusion.targets.map((target) => {
          const isWinner = target.targetId === fusion.winner?.targetId;
          return (
            <li
              key={target.targetId}
              data-testid="fusion-target"
              data-winner={isWinner ? "true" : "false"}
              className={`fusion-hud__target${isWinner ? " fusion-hud__target--winner" : ""}`}
            >
              <span className="fusion-hud__label">{target.label}</span>
              <span className="fusion-hud__pct">{pct(target.fusedConfidence)}</span>
              <span
                className="fusion-hud__bar"
                style={{ width: pct(target.fusedConfidence) }}
                aria-hidden="true"
              />
              <span className="fusion-hud__votes">
                {target.votes.map((vote) => (
                  <span key={vote.source} className="fusion-hud__vote" title={pct(vote.confidence)}>
                    {vote.source}
                  </span>
                ))}
              </span>
            </li>
          );
        })}
      </ul>

      {fusion.drag && (
        <p data-testid="fusion-drag" className="fusion-hud__drag" data-drag={fusion.drag.reason}>
          <span className="fusion-hud__drag-source">{fusion.drag.source}</span> {fusion.drag.detail}
        </p>
      )}
    </section>
  );
}
