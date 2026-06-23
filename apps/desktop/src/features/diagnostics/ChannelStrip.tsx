import type { ReactNode } from "react";

// One model's live readout for the mixing-board view: its status, confidence, and
// current verdict, plus solo/mute and a slot for the input monitor (camera canvas
// or voice waveform). Presentational — state lives in the diagnostics controller.
export type ChannelStatus = "live" | "idle" | "no_signal" | "error";

export type ChannelSample = {
  id: string;
  label: string;
  status: ChannelStatus;
  confidence: number;
  detail?: string;
  fps?: number;
};

type ChannelStripProps = {
  sample: ChannelSample;
  soloed?: boolean;
  muted?: boolean;
  onSolo?: () => void;
  onMute?: () => void;
  children?: ReactNode;
};

const pct = (value: number): string => `${Math.round(value * 100)}%`;

export function ChannelStrip({
  sample,
  soloed,
  muted,
  onSolo,
  onMute,
  children,
}: ChannelStripProps) {
  const isNoSignal = sample.status === "no_signal";

  return (
    <section
      data-testid="channel-strip"
      data-status={sample.status}
      className={`channel-strip channel-strip--${sample.status}`}
    >
      <header className="channel-strip__head">
        <span className="channel-strip__label">{sample.label}</span>
        <span className="channel-strip__lamp" aria-label={`status ${sample.status}`} />
        {sample.fps !== undefined && <span className="channel-strip__fps">{sample.fps} fps</span>}
      </header>

      <div className="channel-strip__monitor">{children}</div>

      <div className="channel-strip__meter">
        {isNoSignal ? (
          <span className="channel-strip__nosignal">No signal</span>
        ) : (
          <>
            <span className="channel-strip__pct">{pct(sample.confidence)}</span>
            <span
              className="channel-strip__bar"
              style={{ width: pct(sample.confidence) }}
              aria-hidden="true"
            />
          </>
        )}
      </div>

      {sample.detail && <p className="channel-strip__detail">{sample.detail}</p>}

      <div className="channel-strip__controls">
        <button type="button" aria-pressed={soloed ?? false} onClick={onSolo}>
          Solo
        </button>
        <button type="button" aria-pressed={muted ?? false} onClick={onMute}>
          Mute
        </button>
      </div>
    </section>
  );
}
