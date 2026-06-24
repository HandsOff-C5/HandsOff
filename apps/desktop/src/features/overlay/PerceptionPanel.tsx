import { VOICE_STATE_LABEL, type OverlayVoiceState } from "./overlay-signal";
import {
  formatConfidencePct,
  formatFps,
  modelStatus,
  type ModelTrack,
  type SupervisorSnapshot,
} from "./supervisor-signal";

type PerceptionPanelProps = {
  snapshot: SupervisorSnapshot;
};

// One sensor row: icon + name + live confidence% + frame rate + status lamp +
// what it's locked onto. Reused for the hand and gaze trackers.
function TrackerRow({
  model,
  icon,
  name,
  track,
}: {
  model: "hand" | "gaze";
  icon: string;
  name: string;
  track: ModelTrack;
}) {
  const status = modelStatus(track);
  return (
    <li
      data-testid={`perception-row-${model}`}
      data-status={status}
      className={`perception__row perception__row--${status}`}
    >
      <span className="perception__lamp" aria-hidden="true" />
      <span className="perception__icon" aria-hidden="true">
        {icon}
      </span>
      <span className="perception__name">{name}</span>
      <span className="perception__pct">{formatConfidencePct(track.confidence)}</span>
      <span className="perception__fps">{formatFps(track.fps)}</span>
      {track.lock && (
        <span className="perception__lock">
          <span className="perception__lock-arrow" aria-hidden="true">
            →
          </span>
          <span className="perception__lock-name">{track.lock}</span>
        </span>
      )}
    </li>
  );
}

// Voice engagement is binary "live or not" rather than a confidence — live while
// the operator is listening/heard/acting, idle otherwise.
function voiceStatus(state: OverlayVoiceState): "live" | "idle" {
  return state === "idle" ? "idle" : "live";
}

// The perception panel (top-right of the supervisor HUD): every model on its own
// row so the operator sees, at a glance, which trackers are live, how sure each
// is, and what each is locked onto. Cover the hand and its row reddens to "lost".
export function PerceptionPanel({ snapshot }: PerceptionPanelProps) {
  const voiceState = snapshot.voice.state;
  return (
    <section className="perception" aria-label="Perception">
      <header className="perception__head">Perception</header>
      <ul className="perception__rows">
        <TrackerRow model="hand" icon="✋" name="Hand" track={snapshot.hand} />
        <TrackerRow model="gaze" icon="👁" name="Eyes" track={snapshot.gaze} />
        <li
          data-testid="perception-row-voice"
          data-status={voiceStatus(voiceState)}
          className={`perception__row perception__row--${voiceStatus(voiceState)}`}
        >
          <span className="perception__lamp" aria-hidden="true" />
          <span className="perception__icon" aria-hidden="true">
            🎙
          </span>
          <span className="perception__name">Voice</span>
          <span className="perception__voice-state">{VOICE_STATE_LABEL[voiceState]}</span>
        </li>
      </ul>
    </section>
  );
}
