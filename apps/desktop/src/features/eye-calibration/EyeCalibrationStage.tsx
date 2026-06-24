import { useEffect, useRef } from "react";
import type {
  EyeCalibrationOutcome,
  EyeCalibrationView,
  GazeFeatures,
  GazeOverlayPoint,
} from "@handsoff/gesture";

export type TrackingStatus = "idle" | "loading" | "ready" | "denied" | "failed";

export interface EyeCalibrationStageProps {
  status: TrackingStatus;
  error: string | null;
  // The live webcam stream (shown mirrored so the operator sees themselves).
  stream: MediaStream | null;
  // Iris/eye landmarks to draw on the mirror, normalized [0,1] mesh space.
  points: readonly GazeOverlayPoint[] | null;
  features: GazeFeatures | null;
  // Live eye-tracking confidence [0,1].
  confidence: number;
  view: EyeCalibrationView;
  // Current dot position, union-normalized [0,1] across all monitors; null when done.
  dotUnion: readonly [number, number] | null;
  // 0→1 capture progress for the active dot.
  captureProgress: number;
  outcome: EyeCalibrationOutcome | null;
  onRedo: () => void;
}

const pct = (v: number): string => `${(v * 100).toFixed(3)}%`;
const POINT_FILL: Record<GazeOverlayPoint["kind"], string> = {
  iris: "#ff4d4f",
  corner: "#40a9ff",
  lid: "#ffd666",
};

// The camera mirror with iris landmarks + the live confidence readout. The operator sees
// themselves and exactly what the tracker reads, so "is it working" is answerable at a
// glance — the whole point of this pass.
function CameraMirror({
  stream,
  points,
  features,
  confidence,
  status,
}: Pick<EyeCalibrationStageProps, "stream" | "points" | "features" | "confidence" | "status">) {
  const videoRef = useRef<HTMLVideoElement | null>(null);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    video.srcObject = stream;
    if (stream) void video.play().catch(() => undefined);
  }, [stream]);

  const confPctValue = Math.round(confidence * 100);
  const confClass = confidence >= 0.6 ? "is-good" : confidence >= 0.3 ? "is-fair" : "is-poor";

  return (
    <div className="eyecal__mirror" data-testid="eyecal-mirror">
      <video ref={videoRef} className="eyecal__video" muted playsInline />
      <svg className="eyecal__points" viewBox="0 0 1 1" preserveAspectRatio="none">
        {(points ?? []).map((p, i) => (
          <circle
            key={i}
            cx={1 - p.x}
            cy={p.y}
            r={p.kind === "iris" ? 0.02 : 0.012}
            fill={POINT_FILL[p.kind]}
            data-testid={`eyecal-point-${p.kind}`}
          />
        ))}
      </svg>
      <div className={`eyecal__conf ${confClass}`} data-testid="eyecal-confidence">
        <span className="eyecal__conf-num">{confPctValue}%</span>
        <span className="eyecal__conf-label">eye-tracking confidence</span>
        <div className="eyecal__conf-bar">
          <div className="eyecal__conf-fill" style={{ width: pct(confidence) }} />
        </div>
        <span className="eyecal__conf-status">
          {status === "ready" && features
            ? "tracking your eyes"
            : status === "ready"
              ? "no face detected"
              : status}
        </span>
      </div>
    </div>
  );
}

export function EyeCalibrationStage(props: EyeCalibrationStageProps) {
  const { status, error, view, dotUnion, captureProgress, outcome, onRedo } = props;

  if (status === "denied") {
    return (
      <div className="eyecal" data-testid="eyecal-denied">
        <div className="eyecal__notice">
          <h2>Camera access needed</h2>
          <p>HandsOff needs your webcam to track your eyes. Grant camera access, then relaunch.</p>
          {error ? <p className="eyecal__err">{error}</p> : null}
        </div>
      </div>
    );
  }

  const screenNo = Math.min(view.monitorIndex + 1, view.monitorCount);

  return (
    <div className="eyecal" data-testid="eyecal-stage">
      {/* The dot the operator looks at. */}
      {dotUnion && !view.done ? (
        <div
          className="eyecal__dot"
          data-testid="eyecal-dot"
          style={{ left: pct(dotUnion[0]), top: pct(dotUnion[1]) }}
        >
          <div
            className="eyecal__dot-ring"
            style={{ transform: `scale(${0.4 + 0.6 * captureProgress})` }}
          />
          <div className="eyecal__dot-core" />
        </div>
      ) : null}

      <CameraMirror
        stream={props.stream}
        points={props.points}
        features={props.features}
        confidence={props.confidence}
        status={status}
      />

      {/* Progress / instructions HUD. */}
      <div className="eyecal__hud" data-testid="eyecal-hud">
        {view.done ? (
          <div className="eyecal__done">
            <h2>Calibration complete</h2>
            <ul className="eyecal__fits">
              {(outcome?.fits ?? []).map((f) => (
                <li key={f.monitorIndex}>
                  Screen {f.monitorIndex + 1}: <strong>{f.quality}</strong> (
                  {f.residualPx.toFixed(0)}px)
                </li>
              ))}
            </ul>
            <button type="button" className="eyecal__btn" onClick={onRedo}>
              Calibrate again
            </button>
          </div>
        ) : (
          <>
            <p className="eyecal__step">
              Screen {screenNo} of {view.monitorCount} · dot {view.dotIndex + 1}/
              {view.dotsPerMonitor}
            </p>
            <p className="eyecal__hint">
              Look at the glowing dot until it locks in. Keep your head still.
            </p>
          </>
        )}
      </div>
    </div>
  );
}
