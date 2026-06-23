import type { ClarificationRequest } from "@handsoff/contracts";

import { EmptyPanel } from "../../components/EmptyPanel";

type ClarificationPanelProps = {
  request?: ClarificationRequest | null;
  onPick?: (targetId: string) => void;
  onCancel?: () => void;
};

// Renders the structured clarification ask (#36) — the "which one?" beat when the
// engine won't act blind (AD5). The question already encodes the reason; options
// list the calibrated-confidence (#100) candidates the user can pick.
export function ClarificationPanel({ request, onPick, onCancel }: ClarificationPanelProps) {
  if (!request) {
    return (
      <EmptyPanel
        title="Clarification"
        message="No clarification needed. Ambiguous or low-confidence selections show here to confirm."
      />
    );
  }

  return (
    <section className="panel clarification">
      <h2 className="panel__title">Clarification</h2>
      <p className="clarification__question">{request.question}</p>
      {request.options.length > 0 ? (
        <ul className="clarification__options">
          {request.options.map((option) => (
            <li key={option.targetId} className="clarification__option">
              <span className="clarification__label">{option.label}</span>
              <span className="clarification__confidence">
                {Math.round(option.confidence * 100)}%
              </span>
              {onPick ? (
                <button type="button" onClick={() => onPick(option.targetId)}>
                  Pick
                </button>
              ) : null}
            </li>
          ))}
        </ul>
      ) : null}
      {onCancel ? (
        <div className="clarification__actions">
          <button type="button" onClick={onCancel}>
            Cancel
          </button>
        </div>
      ) : null}
    </section>
  );
}
