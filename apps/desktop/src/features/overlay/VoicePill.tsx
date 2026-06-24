import { VOICE_STATE_LABEL, type OverlayVoiceState } from "./overlay-signal";

type VoicePillProps = {
  voice: { state: OverlayVoiceState; transcript: string | null };
};

// The voice pill (top-center of the supervisor HUD): the engagement state
// (Ready → Listening → Heard → Acting) plus the last words the operator said,
// so they can see the system heard them correctly without the dashboard.
export function VoicePill({ voice }: VoicePillProps) {
  return (
    <div
      data-testid="voice-pill"
      data-voice-state={voice.state}
      className={`voice-pill voice-pill--${voice.state}`}
    >
      <span className="voice-pill__lamp" aria-hidden="true" />
      <span className="voice-pill__state">{VOICE_STATE_LABEL[voice.state]}</span>
      {voice.transcript && (
        <span data-testid="voice-pill-transcript" className="voice-pill__transcript">
          {voice.transcript}
        </span>
      )}
    </div>
  );
}
