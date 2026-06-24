import type { GazeFeatures, GazeOverlayPoint } from "@handsoff/gesture";
import { useEffect, useRef } from "react";
import { createPortal } from "react-dom";

// On-screen verification view for eye-gaze: a live mirror of the camera with the iris
// centers, eye corners, and lids drawn on the eyes, plus the live feature readout. Lets
// the user SEE what the tracker reads (look left↔right → irisX moves; blink → eyeAspect
// drops) BEFORE we build calibration on it.
//
// It is portaled to an on-screen root (#overlay-debug-root) so it is visible on the real
// desktop — the camera shell itself lives in the off-screen engine-host. The <video>
// shares the SAME MediaStream the camera loop already opened (no second camera).

interface GazeDebugOverlayProps {
  // The live camera stream the camera loop opened (shared, not re-acquired).
  readonly stream: MediaStream | null;
  // Iris/corner/lid points to draw (normalized [0,1]), or null with no face.
  readonly points: readonly GazeOverlayPoint[] | null;
  // Live feature readout, or null with no face.
  readonly features: GazeFeatures | null;
  // Selfie mirror — matches the camera video's CSS flip so dots land on the eyes.
  readonly mirrored?: boolean;
}

const KIND_FILL: Record<GazeOverlayPoint["kind"], string> = {
  iris: "#ff4d4f",
  corner: "#40a9ff",
  lid: "#ffd666",
};

export function GazeDebugOverlay({
  stream,
  points,
  features,
  mirrored = true,
}: GazeDebugOverlayProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    video.srcObject = stream;
    if (stream) void video.play().catch(() => {});
  }, [stream]);

  const node = (
    <section className="gaze-debug" aria-label="Eye tracking debug">
      <header className="gaze-debug__title">Eye tracking — what the camera reads</header>
      <div className="gaze-debug__stage">
        <video
          ref={videoRef}
          className={`gaze-debug__video${mirrored ? " gaze-debug__video--mirrored" : ""}`}
          muted
          playsInline
          aria-label="eye tracking camera"
        />
        {points && (
          <svg
            className="gaze-debug__svg"
            viewBox="0 0 1 1"
            preserveAspectRatio="none"
            aria-hidden="true"
          >
            {points.map((p, i) => (
              <circle
                key={i}
                data-testid={`gaze-point-${p.kind}`}
                cx={mirrored ? 1 - p.x : p.x}
                cy={p.y}
                r={p.kind === "iris" ? 0.014 : 0.008}
                fill={KIND_FILL[p.kind]}
              />
            ))}
          </svg>
        )}
      </div>
      {features ? (
        <dl className="gaze-debug__readout">
          <div>
            <dt>iris L</dt>
            <dd>
              {features.irisXL.toFixed(2)}, {features.irisYL.toFixed(2)}
            </dd>
          </div>
          <div>
            <dt>iris R</dt>
            <dd>
              {features.irisXR.toFixed(2)}, {features.irisYR.toFixed(2)}
            </dd>
          </div>
          <div>
            <dt>eye aspect</dt>
            <dd>{features.eyeAspect.toFixed(2)}</dd>
          </div>
        </dl>
      ) : (
        <p className="gaze-debug__empty">No face detected.</p>
      )}
    </section>
  );

  const root =
    typeof document !== "undefined" ? document.getElementById("overlay-debug-root") : null;
  return root ? createPortal(node, root) : node;
}
