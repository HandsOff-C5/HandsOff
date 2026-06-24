import { agentBannerText, type AgentState } from "./supervisor-signal";

type AgentBannerProps = {
  agent: AgentState;
  // Approve/deny the pending mutating step. Click is one path; voice ("approve"/
  // "deny") is the other — both resolve the same queued action (hands-off).
  onApprove?: () => void;
  onDeny?: () => void;
};

// The agent banner (bottom of the supervisor HUD): the CUA's current action in
// plain words, plus — when a mutating step is queued — an approval chip the
// operator can click (or answer by voice) without leaving the overlay.
export function AgentBanner({ agent, onApprove, onDeny }: AgentBannerProps) {
  return (
    <section className="agent-banner" aria-label="Agent" data-pending={agent.pendingApproval}>
      <p className="agent-banner__action">
        <span className="agent-banner__glyph" aria-hidden="true">
          {agent.action ? "⏵" : "·"}
        </span>{" "}
        {agentBannerText(agent)}
      </p>
      {agent.pendingApproval && (
        <div className="agent-banner__chip" role="group" aria-label="Approve this step?">
          <span className="agent-banner__ask">⏸ Approve this step?</span>
          <button type="button" className="agent-banner__approve" onClick={() => onApprove?.()}>
            ✓ approve
          </button>
          <button type="button" className="agent-banner__deny" onClick={() => onDeny?.()}>
            ✗ deny
          </button>
          <span className="agent-banner__hint">or say “approve” / “deny”</span>
        </div>
      )}
    </section>
  );
}
