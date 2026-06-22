import type { LandmarkFrame } from "@handsoff/contracts";

// #25 debug overlay — draws the MediaPipe hand landmarks plus a per-hand handedness /
// confidence readout and the live FPS. Pure presentation: it takes the parsed
// LandmarkFrame produced by the detection loop and renders it; the camera + detector
// wiring lives in the CameraPanel shell.

interface LandmarkOverlayProps {
  // The latest parsed frame, or null before the first detection.
  frame: LandmarkFrame | null;
  // Frames per second from the detection loop.
  fps: number;
}

export function LandmarkOverlay({ frame, fps }: LandmarkOverlayProps) {
  const hands = frame?.hands ?? [];

  return (
    <div className="landmark-overlay">
      <div className="landmark-overlay__hud">
        <span className="landmark-overlay__fps">{Math.round(fps)} FPS</span>
      </div>

      {hands.length === 0 ? (
        <p className="landmark-overlay__empty">No hand detected.</p>
      ) : (
        <>
          {/* Landmarks are normalized to [0,1], so the SVG uses a unit viewBox and
              scales to its container. */}
          <svg
            className="landmark-overlay__canvas"
            viewBox="0 0 1 1"
            preserveAspectRatio="none"
            aria-hidden="true"
          >
            {hands.flatMap((hand, h) =>
              hand.landmarks.map((l, i) => (
                <circle key={`${h}-${i}`} data-testid="landmark" cx={l.x} cy={l.y} r={0.01} />
              )),
            )}
          </svg>

          <ul className="landmark-overlay__readouts">
            {hands.map((hand, h) => (
              <li key={h} data-testid={`hand-readout-${h}`} className="landmark-overlay__readout">
                <span>{hand.handedness}</span> <span>{Math.round(hand.score * 100)}%</span>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}
