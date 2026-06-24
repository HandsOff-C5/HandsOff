import { useEffect, useState } from "react";

import { CalibrationGate } from "../calibration/CalibrationGate";
import type { CalibrationView } from "../calibration/calibration-flow";
import { AgentBanner } from "./AgentBanner";
import { FusionHud } from "./FusionHud";
import { PerceptionPanel } from "./PerceptionPanel";
import { VoicePill } from "./VoicePill";
import { useFusionSignal, type FusionListen } from "./useFusionSignal";
import {
  IDLE_OVERLAY_SIGNAL,
  overlayMarkerStyle,
  VOICE_STATE_LABEL,
  type OverlayPointerUpdate,
  type OverlaySignal,
  type OverlayVoiceState,
} from "./overlay-signal";
import type { SupervisorSnapshot } from "./supervisor-signal";

// Subscribes the overlay to the main window's streams: pointer updates (geometry +
// confidence + lock) and voice-state changes. Injected so the window wiring uses Tauri
// `listen` while tests push synchronously. Returns an unsubscribe.
export type OverlayListen = (
  onPointer: (update: OverlayPointerUpdate) => void,
  onVoice: (voiceState: OverlayVoiceState) => void,
) => () => void;

// Subscribes the overlay to the engine's per-model supervisor snapshot (each
// tracker's cursor/confidence/fps/lock + voice transcript + agent action). Injected
// like the others so the overlay window uses Tauri `listen` while tests push directly.
export type SupervisorListen = (onSnapshot: (snapshot: SupervisorSnapshot) => void) => () => void;

// Subscribes the overlay to the engine's startup calibration view (null = not running).
export type CalibrationListen = (onView: (view: CalibrationView | null) => void) => () => void;

export function useOverlaySignal(listen?: OverlayListen): OverlaySignal {
  const [signal, setSignal] = useState<OverlaySignal>(IDLE_OVERLAY_SIGNAL);
  useEffect(() => {
    if (!listen) return;
    return listen(
      (update) => setSignal((prev) => ({ ...prev, ...update })),
      (voiceState) => setSignal((prev) => ({ ...prev, voiceState })),
    );
  }, [listen]);
  return signal;
}

export function useSupervisorSignal(listen?: SupervisorListen): SupervisorSnapshot | null {
  const [snapshot, setSnapshot] = useState<SupervisorSnapshot | null>(null);
  useEffect(() => {
    if (!listen) return;
    return listen((next) => setSnapshot(next));
  }, [listen]);
  return snapshot;
}

export function useCalibrationSignal(listen?: CalibrationListen): CalibrationView | null {
  const [view, setView] = useState<CalibrationView | null>(null);
  useEffect(() => {
    if (!listen) return;
    return listen((next) => setView(next));
  }, [listen]);
  return view;
}

interface PointingOverlayProps {
  // Presentational override (tests). When omitted, the live signal from `listen` is used.
  signal?: OverlaySignal;
  // Live subscription (the overlay window passes the Tauri-backed listener).
  listen?: OverlayListen;
  // Per-frame fused evidence subscription (the overlay window passes the Tauri-backed
  // listener). Drives the on-screen FusionHud so every model's live confidence + vote +
  // the disagreement "drag" is visible on the real desktop, not just in the dashboard.
  fusionListen?: FusionListen;
  // The richer per-model supervisor snapshot (override for tests).
  supervisor?: SupervisorSnapshot;
  // Live supervisor-snapshot subscription (the overlay window passes the Tauri listener).
  supervisorListen?: SupervisorListen;
  // Approve / deny the agent's pending mutating step from the overlay chip (click path;
  // voice is the other path). Wired to the engine's CUA approval controller.
  onApprove?: () => void;
  onDeny?: () => void;
  // Startup calibration: the dots-to-touch view (override for tests) + live subscription,
  // and the skip control sent back to the engine. While a view is active the gate is
  // shown INSTEAD of the HUD.
  calibration?: CalibrationView | null;
  calibrationListen?: CalibrationListen;
  onCalibrationSkip?: () => void;
}

// Clamp a normalized [0,1] point to a CSS percent position, or hide it off-frame.
function cursorPosition(point: [number, number] | null): { left: string; top: string } | null {
  if (!point) return null;
  const clamp = (v: number): number => Math.min(1, Math.max(0, Number.isFinite(v) ? v : 0));
  return { left: `${clamp(point[0]) * 100}%`, top: `${clamp(point[1]) * 100}%` };
}

// The supervisor HUD: the full overlay-as-UI surface. Two live desktop cursors
// (cyan dot = hand, amber ring = eyes), the per-model perception panel, the fused
// row, the voice pill, and the agent banner — every model's tracking + accuracy
// AND the CUA's actions, painted on the real desktop.
function SupervisorHud({
  supervisor,
  fusion,
  onApprove,
  onDeny,
}: {
  supervisor: SupervisorSnapshot;
  fusion: ReturnType<typeof useFusionSignal>;
  onApprove?: () => void;
  onDeny?: () => void;
}) {
  const hand = cursorPosition(supervisor.hand.point);
  const gaze = cursorPosition(supervisor.gaze.point);
  return (
    <>
      {hand && supervisor.hand.point && (
        <div
          data-testid="cursor-hand"
          className="overlay-cursor overlay-cursor--hand"
          style={{
            ...hand,
            ...overlayMarkerStyle(supervisor.hand.point, supervisor.hand.confidence),
          }}
          aria-hidden="true"
        />
      )}
      {gaze && (
        <div
          data-testid="cursor-gaze"
          className="overlay-cursor overlay-cursor--gaze"
          style={gaze}
          aria-hidden="true"
        />
      )}
      <div className="supervisor-hud__voice">
        <VoicePill voice={supervisor.voice} />
      </div>
      <div className="supervisor-hud__perception">
        <PerceptionPanel snapshot={supervisor} />
        <FusionHud fusion={fusion} />
      </div>
      <div className="supervisor-hud__agent">
        <AgentBanner
          agent={supervisor.agent}
          {...(onApprove ? { onApprove } : {})}
          {...(onDeny ? { onDeny } : {})}
        />
      </div>
    </>
  );
}

// Full-screen pointing overlay (#25 cursor seam), now the overlay-as-UI surface. In its
// own transparent, click-through, always-on-top window over the real desktop. With a
// supervisor snapshot it renders the full HUD (two cursors + perception + fusion + voice
// + agent); without one it falls back to the bare single-pointer layer (legacy/tests).
export function PointingOverlay({
  signal: signalProp,
  listen,
  fusionListen,
  supervisor: supervisorProp,
  supervisorListen,
  onApprove,
  onDeny,
  calibration: calibrationProp,
  calibrationListen,
  onCalibrationSkip,
}: PointingOverlayProps) {
  const live = useOverlaySignal(listen);
  const signal = signalProp ?? live;
  const fusion = useFusionSignal(fusionListen);
  const liveSupervisor = useSupervisorSignal(supervisorListen);
  const supervisor = supervisorProp ?? liveSupervisor;
  const liveCalibration = useCalibrationSignal(calibrationListen);
  const calibration = calibrationProp ?? liveCalibration;

  // The shared bundle's body is opaque dark (dashboard theme); the overlay window must
  // be see-through, so clear the background while this layer is mounted.
  useEffect(() => {
    const { body, documentElement } = document;
    const prev = { body: body.style.background, html: documentElement.style.background };
    body.style.background = "transparent";
    documentElement.style.background = "transparent";
    return () => {
      body.style.background = prev.body;
      documentElement.style.background = prev.html;
    };
  }, []);

  // Startup calibration takes over the whole overlay until it's done/skipped: the
  // operator touches the dots (hand, then eyes) before the HUD goes live. The live
  // cursor shown is the active phase's tracker, reused from the supervisor snapshot.
  if (calibration?.active) {
    const cursor =
      calibration.phase === "hand"
        ? (supervisor?.hand.point ?? null)
        : (supervisor?.gaze.point ?? null);
    return (
      <div className="pointing-overlay pointing-overlay--calibrating">
        <CalibrationGate view={calibration} cursor={cursor} onSkip={() => onCalibrationSkip?.()} />
      </div>
    );
  }

  if (supervisor) {
    return (
      <div className="pointing-overlay pointing-overlay--supervisor">
        <SupervisorHud
          supervisor={supervisor}
          fusion={fusion}
          {...(onApprove ? { onApprove } : {})}
          {...(onDeny ? { onDeny } : {})}
        />
      </div>
    );
  }

  return (
    <div className="pointing-overlay" aria-hidden="true">
      {signal.point && (
        <div
          data-testid="overlay-marker"
          className="pointing-overlay__marker"
          style={overlayMarkerStyle(signal.point, signal.confidence)}
        />
      )}
      {signal.targetLabel && (
        <p className="pointing-overlay__target" style={markerLabelStyle(signal.point)}>
          {signal.targetLabel}
        </p>
      )}
      <p
        className={`pointing-overlay__voice pointing-overlay__voice--${signal.voiceState}`}
        data-voice-state={signal.voiceState}
      >
        {VOICE_STATE_LABEL[signal.voiceState]}
      </p>
      {/* Live per-model accuracy on the real screen: each tracker's confidence +
          vote + the disagreement drag, fused every frame. */}
      <div className="pointing-overlay__hud">
        <FusionHud fusion={fusion} />
      </div>
    </div>
  );
}

// Pin the target label just under the marker when there's a point; otherwise hide it.
function markerLabelStyle(
  point: OverlaySignal["point"],
): { left: string; top: string } | undefined {
  if (!point) return undefined;
  const clamp = (v: number): number => Math.min(1, Math.max(0, v));
  return { left: `${clamp(point[0]) * 100}%`, top: `${clamp(point[1]) * 100}%` };
}
