import {
  APP_NAME,
  type CalibrationQuality,
  type CapabilityId,
  type IntentInput,
  type PointingEvidence,
  type ResolvedIntent,
  type SttProvider,
  type SttStream,
} from "@handsoff/contracts";
import {
  createApprovalController,
  createTauriCuaDriver,
  createTauriCuaEscalator,
  createUnavailableCuaDriver,
  type CuaDriver,
  type TauriCuaEscalator,
} from "@handsoff/cua";
import { planPermissionOnboarding } from "@handsoff/desktop";
import {
  createAssemblyAiStream,
  createOnDeviceSttStream,
  type CaptureStatus,
} from "@handsoff/speech";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";

import { applyTransform, type AffineTransform, type Point } from "@handsoff/gesture";

import { CameraPanel } from "../../features/camera/CameraPanel";
import { DEMO_SCREEN_BOUNDS } from "../../features/camera/demo-surfaces";
import { useCalibrationOnboarding } from "../../features/calibration/useCalibrationOnboarding";
import { ClarificationPanel } from "../../features/clarification/ClarificationPanel";
import { CuaApprovalPanel } from "../../features/cua-approval/CuaApprovalPanel";
import { useCuaApproval } from "../../features/cua-approval/useCuaApproval";
import { DiagnosticsScreen } from "../../features/diagnostics/DiagnosticsScreen";
import { deriveVoiceState, type OverlayPointerUpdate } from "../../features/overlay/overlay-signal";
import {
  describeCuaAgentAction,
  fpsFromTimestamps,
  type SupervisorSnapshot,
} from "../../features/overlay/supervisor-signal";
import {
  emitOverlayFusion,
  emitOverlayPointer,
  emitOverlaySupervisor,
  emitOverlayVoice,
  listenOverlayApproval,
} from "../../features/overlay/tauri-overlay";
import { PermissionsOnboarding } from "../../features/permissions/PermissionsOnboarding";
import { PermissionsPanel } from "../../features/permissions/PermissionsPanel";
import { PlanPreviewPanel } from "../../features/plan-preview/PlanPreviewPanel";
import { ReadinessPanel } from "../../features/readiness/ReadinessPanel";
import { useReadinessProbe } from "../../features/readiness/useReadinessProbe";
import { SessionsPanel } from "../../features/sessions/SessionsPanel";
import { SettingsPanel } from "../../features/settings/SettingsPanel";
import {
  useHeadPointing,
  type HeadPointingSnapshot,
  type HeadPointingListen,
} from "../../features/head-pointing/useHeadPointing";
import { useLocalConfig } from "../../features/settings/useLocalConfig";
import { TranscriptPanel } from "../../features/transcript/TranscriptPanel";
import { parseApprovalUtterance } from "../../features/voice-cua/approval-voice";
import {
  createIntentWorkerResolver,
  useVoiceCuaController,
} from "../../features/voice-cua/useVoiceCuaController";
import { hasTauriBackend } from "../../lib/tauri";
import type { ResolveIntentOptions } from "@handsoff/intent";

// "Native" mode (#31, AD2): recognition runs in the app process via native
// Objective-C (SFSpeechRecognizer + AVAudioEngine) driven by the `stt_ondevice_*`
// commands — no API key, no network, no provisioning.
function createOnDeviceStream(): SttStream {
  return createOnDeviceSttStream({
    invoke: (command) => invoke(command),
    listen: (event, handler) => listen(event, ({ payload }) => handler({ payload })),
  });
}

// "Realtime" mode: hosted streaming whose token is minted by the Rust host via
// the HandsOff token Worker, so provider credentials never reach the webview.
// Without Worker app-auth config it surfaces a recoverable transcript error.
function createRealtimeStream(): SttStream {
  return createAssemblyAiStream({
    tokenProvider: async () => {
      const result = await invoke<{ token: string }>("stt_mint_token", { expiresInSeconds: 60 });
      return result.token;
    },
  });
}

// Assemble the per-frame pointing evidence for the diagnostics board from the live
// signals the dashboard holds: the locked gesture referent (#35) and the head/gaze
// candidates (#95) — the same shape the controller fuses. (Continuous per-frame emit
// is a follow-up; this reflects the latest gesture lock + head stream.)
function buildDiagnosticsEvidence(
  gesture: PointingEvidence | null,
  headPointing: HeadPointingSnapshot | undefined,
): PointingEvidence[] {
  const evidence: PointingEvidence[] = [];
  if (gesture) evidence.push(gesture);
  for (const candidate of headPointing?.candidates ?? []) {
    evidence.push({
      source: "head",
      confidence: candidate.score,
      strategy: "head-neighborhood",
      surface: candidate.surface,
      ...(headPointing?.point ? { cursor: headPointing.point } : {}),
    });
  }
  return evidence;
}

// Calibration persistence. The hand calibration reuses the camera panel's key (so
// onboarding and the in-panel Calibrate flow share one stored fit); the gaze
// correction gets its own. A stored hand calibration means we skip the onboarding.
const HAND_CALIB_KEY = "handsoff.calibration.v2";
const GAZE_CALIB_KEY = "handsoff.calibration.gaze.v1";

function hasStoredHandCalibration(): boolean {
  try {
    return localStorage.getItem(HAND_CALIB_KEY) !== null;
  } catch {
    return false;
  }
}

const HEAD_POINTING_TAURI = {
  invoke: (command: string) => invoke(command),
  listen: ((event, handler) =>
    listen(event, ({ payload }) => handler({ payload }))) satisfies HeadPointingListen,
};

// The transcription mode the user picked in Settings decides which provider the
// transcript panel speaks to. Both satisfy the same `SttStream` seam, so the
// panel and intent engine are unchanged.
function streamFactoryFor(provider: SttProvider): () => SttStream {
  return provider === "assemblyai" ? createRealtimeStream : createOnDeviceStream;
}

interface DashboardProps {
  createStream?: () => SttStream;
  cuaDriver?: CuaDriver;
  cuaEscalator?: TauriCuaEscalator;
  headPointing?: HeadPointingSnapshot;
  resolveIntent?: (input: IntentInput, options: ResolveIntentOptions) => Promise<ResolvedIntent>;
  now?: () => string;
  targetResolveDelayMs?: number;
}

// Mission-control dashboard shell (issue #15). Branded header plus one panel per
// core-loop concern. Readiness (#17) and permission education (#18) share one
// host probe: the readiness panel shows status at a glance, the permissions panel
// turns missing macOS grants into targeted setup steps and a re-check. The
// transcript panel (#31) turns speech into visible partial/final transcripts.
export function Dashboard({
  createStream: injectedStream,
  cuaDriver,
  cuaEscalator: injectedEscalator,
  headPointing: injectedHeadPointing,
  resolveIntent,
  now,
  targetResolveDelayMs,
}: DashboardProps = {}) {
  const { report, isChecking, recheck } = useReadinessProbe();
  const { config, status, updateConfig, resetConfig } = useLocalConfig();
  const createStream =
    injectedStream ?? (hasTauriBackend() ? streamFactoryFor(config.sttProvider) : undefined);
  const driver =
    cuaDriver ??
    (hasTauriBackend()
      ? createTauriCuaDriver((command, args) => invoke(command, args))
      : createUnavailableCuaDriver());
  // Latest locked gesture referent (#35). The CameraPanel writes it on lock/unlock;
  // the controller reads it at intent time so "point + speak" binds to the pointed
  // surface. A ref (not state) avoids re-rendering the dashboard on every lock.
  const gestureEvidence = useRef<PointingEvidence | null>(null);
  // Head/gaze attention (#95): the worker-proxied LLM resolver + the live head-pointing
  // stream, folded into the same controller so gesture, head, and voice fuse together.
  const intentResolver =
    resolveIntent ??
    (hasTauriBackend()
      ? createIntentWorkerResolver((command, args) => invoke(command, args))
      : undefined);
  const liveHeadPointing = useHeadPointing(hasTauriBackend() ? HEAD_POINTING_TAURI : undefined);
  const headPointing = injectedHeadPointing ?? liveHeadPointing;

  // Continuous observability (the whole-screen HUD): stream the fused per-model
  // evidence to the overlay window EVERY frame. The camera pushes its live hand
  // evidence into a ref; we combine it with the gaze candidates and emit, so the
  // on-screen FusionHud shows all models' live confidence + the disagreement drag.
  const handFrameEvidence = useRef<PointingEvidence | null>(null);
  const headPointingRef = useRef(headPointing);
  headPointingRef.current = headPointing;
  const emitLiveFusion = useCallback(() => {
    const evidence: PointingEvidence[] = [];
    if (handFrameEvidence.current) evidence.push(handFrameEvidence.current);
    const head = headPointingRef.current;
    for (const candidate of head?.candidates ?? []) {
      evidence.push({
        source: "head",
        confidence: candidate.score,
        strategy: "head-neighborhood",
        surface: candidate.surface,
        ...(head?.point ? { cursor: head.point } : {}),
      });
    }
    emitOverlayFusion(evidence);
  }, []);
  // Re-emit whenever the gaze changes; the camera callback covers hand-frame changes.
  useEffect(() => {
    emitLiveFusion();
  }, [headPointing, emitLiveFusion]);

  // Supervisor HUD feed (overlay-as-UI): the engine streams a per-model snapshot
  // — each tracker's own cursor/confidence/fps/lock, the voice transcript, and the
  // agent's current action — to the overlay every frame. Fresh values are mirrored
  // into refs so the emit stays a stable callback. fps is measured from a short
  // window of per-source frame timestamps.
  const handPointerRef = useRef<OverlayPointerUpdate | null>(null);
  const handTsRef = useRef<number[]>([]);
  const gazeTsRef = useRef<number[]>([]);
  const lastTranscriptRef = useRef<string | null>(null);
  const pushTimestamp = (ref: { current: number[] }): void => {
    ref.current = [...ref.current.slice(-11), performance.now()];
  };
  // Calibration: the raw hand pointing signal (mirrored from the camera) the
  // onboarding captures to fit, and the fitted gaze correction applied to the gaze
  // point before it's shown/used.
  const rawHandRef = useRef<Point | null>(null);
  const gazeCorrectionRef = useRef<AffineTransform | null>(null);
  useEffect(() => {
    if (!hasTauriBackend()) return;
    void invoke("show_overlay").catch(() => {});
    void invoke("head_track_start").catch(() => {});
  }, []);
  // CUA-5: the agent escalator + its human approval queue. One stable approval
  // controller backs both the escalator's gate and the CuaApprovalPanel, so the
  // panel renders and resolves the mutating actions the agent loop queues.
  const cuaApprovalController = useRef(createApprovalController()).current;
  const cuaEscalator =
    injectedEscalator ??
    (hasTauriBackend()
      ? createTauriCuaEscalator({
          invoke: (command, commandArgs) => invoke(command, commandArgs),
          approval: cuaApprovalController,
        })
      : undefined);
  const approvalController = injectedEscalator?.approval ?? cuaApprovalController;
  const cuaApproval = useCuaApproval(approvalController);
  const { intent, runResult, session, auditEvents, approve, reject, handleFinalTranscript } =
    useVoiceCuaController({
      driver,
      headPointing,
      now,
      resolveIntent: intentResolver,
      targetResolveDelayMs,
      getGestureEvidence: () => gestureEvidence.current,
      ...(cuaEscalator ? { escalate: cuaEscalator.escalate } : {}),
    });
  // The structured clarification prompt (#36) when the engine won't act blind.
  // Display-first; interactive pick→re-resolve needs a controller round-trip (follow-up).
  const clarification =
    intent?.status === "clarification_required" ? (intent.clarification ?? null) : null;

  // Voice engagement state for the screen overlay (#25): listening (mic open) → heard
  // (intent resolved) → acting (plan running). Relayed to the overlay window on change.
  const [captureStatus, setCaptureStatus] = useState<CaptureStatus>("idle");
  const voiceState = deriveVoiceState({
    captureStatus,
    hasIntent: intent !== null,
    running: runResult?.status === "running",
  });
  useEffect(() => emitOverlayVoice(voiceState), [voiceState]);

  // Assemble + emit the supervisor snapshot. Reads the freshest values from refs
  // (mirrored each render below) so it can stay a stable callback. The agent line
  // is the pending step (turned to plain words) while one is queued, else "working"
  // while a plan runs, else idle.
  const voiceStateRef = useRef(voiceState);
  voiceStateRef.current = voiceState;
  const pendingRef = useRef(cuaApproval.pending);
  pendingRef.current = cuaApproval.pending;
  const runningRef = useRef(runResult?.status === "running");
  runningRef.current = runResult?.status === "running";
  const emitSupervisor = useCallback(() => {
    const hand = handPointerRef.current;
    const head = headPointingRef.current;
    const topGaze = head?.candidates?.[0];
    const pending = pendingRef.current[0];
    // Apply the gaze calibration correction to the raw gaze point, if calibrated.
    let gazePoint: [number, number] | null = head?.point ? [head.point.x, head.point.y] : null;
    if (gazePoint && gazeCorrectionRef.current) {
      const corrected = applyTransform(gazeCorrectionRef.current, gazePoint);
      gazePoint = [corrected[0], corrected[1]];
    }
    const snapshot: SupervisorSnapshot = {
      hand: {
        point: hand?.point ?? null,
        confidence: hand?.confidence ?? 0,
        fps: fpsFromTimestamps(handTsRef.current),
        lock: hand?.targetLabel ?? null,
      },
      gaze: {
        point: gazePoint,
        confidence: topGaze?.score ?? 0,
        fps: fpsFromTimestamps(gazeTsRef.current),
        lock: topGaze ? (topGaze.surface.app ?? topGaze.surface.title ?? null) : null,
      },
      voice: { state: voiceStateRef.current, transcript: lastTranscriptRef.current },
      agent: {
        action: pending
          ? describeCuaAgentAction(pending.action)
          : runningRef.current
            ? "working…"
            : null,
        pendingApproval: pendingRef.current.length > 0,
      },
    };
    emitOverlaySupervisor(snapshot);
  }, []);
  // Re-emit on gaze, voice, or agent-state change; the camera callback covers hand frames.
  useEffect(() => {
    pushTimestamp(gazeTsRef);
    emitSupervisor();
  }, [headPointing, emitSupervisor]);
  useEffect(() => {
    emitSupervisor();
  }, [voiceState, cuaApproval.pending, runResult, emitSupervisor]);

  // Startup calibration onboarding (touch the dots): hand 👆 then eyes 👁, before
  // the HUD goes live. The fitted hand calibration is pushed into the camera via
  // calibrationOverride; the gaze fit becomes a local correction applied above.
  // Skipped when a hand calibration is already remembered.
  const [handCalibrationOverride, setHandCalibrationOverride] = useState<{
    transform: AffineTransform;
    quality: CalibrationQuality;
  } | null>(null);
  useEffect(() => {
    try {
      const saved = localStorage.getItem(GAZE_CALIB_KEY);
      if (saved) {
        gazeCorrectionRef.current = (JSON.parse(saved) as { transform: AffineTransform }).transform;
      }
    } catch {
      // Corrupt/absent storage — gaze stays uncorrected.
    }
  }, []);
  useCalibrationOnboarding({
    enabled: hasTauriBackend(),
    handBounds: DEMO_SCREEN_BOUNDS,
    getHandCursor: () => handPointerRef.current?.point ?? null,
    getGazeCursor: () => {
      const point = headPointingRef.current?.point;
      return point ? [point.x, point.y] : null;
    },
    getHandRaw: () => rawHandRef.current,
    getGazeRaw: () => {
      const point = headPointingRef.current?.point;
      return point ? [point.x, point.y] : null;
    },
    onHandResult: (result) =>
      setHandCalibrationOverride({ transform: result.transform, quality: result.quality }),
    onGazeResult: (result) => {
      gazeCorrectionRef.current = result.transform;
      try {
        localStorage.setItem(
          GAZE_CALIB_KEY,
          JSON.stringify({ transform: result.transform, quality: result.quality }),
        );
      } catch {
        // Storage unavailable — the correction still applies this session.
      }
    },
    remembered: hasStoredHandCalibration(),
  });

  // Hands-off approvals (overlay-as-UI phase 4). The approval chip lives in the
  // separate overlay window, so its click comes back as an event the engine
  // resolves against the queue. And while a step is pending we make the overlay
  // interactive (it stops swallowing clicks) so the chip is actually clickable;
  // otherwise the HUD stays click-through and the real desktop is usable.
  useEffect(
    () =>
      listenOverlayApproval((decision) => {
        const pending = pendingRef.current[0];
        if (pending) cuaApproval.decide(pending.id, decision);
      }),
    [cuaApproval],
  );
  useEffect(() => {
    if (!hasTauriBackend()) return;
    void invoke("set_overlay_interactive", {
      interactive: cuaApproval.pending.length > 0,
    }).catch(() => {});
  }, [cuaApproval.pending]);

  // First-run permission onboarding (#18/#56). Show one guided flow on launch
  // until every permission HandsOff needs is granted (or the user skips it),
  // so nobody has to hunt for a per-permission button. Only in the real app.
  const [onboardingDismissed, setOnboardingDismissed] = useState(false);
  const onboardingPlan = planPermissionOnboarding(report);
  const showOnboarding =
    hasTauriBackend() && onboardingPlan.needsOnboarding && !onboardingDismissed;
  // Fire the OS camera prompt by briefly opening a video stream, then release it.
  const requestCamera = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: true });
      stream.getTracks().forEach((track) => track.stop());
    } catch {
      // User denied or no device — the re-check reflects the resulting state.
    }
  };
  const requestMedia = async () => {
    try {
      await invoke("request_media_permissions");
    } catch {
      // Backend unavailable — re-check keeps the last good state.
    }
  };
  const requestScreenRecording = async () => {
    try {
      // Prompts AND registers HandsOff in the Screen Recording list so it's
      // toggleable (granting screen recording usually needs an app relaunch).
      await invoke("request_screen_recording");
    } catch {
      // Backend unavailable — re-check keeps the last good state.
    }
  };
  const openPrivacySettings = (pane: CapabilityId) =>
    void invoke("open_privacy_settings", { pane });
  const relaunchApp = () => void invoke("restart_app");

  // Toggle the full-screen pointing overlay over the real desktop (#25).
  const [overlayShown, setOverlayShown] = useState(false);
  const toggleOverlay = () => {
    void invoke(overlayShown ? "hide_overlay" : "show_overlay");
    setOverlayShown((shown) => !shown);
  };

  // Toggle the diagnostics mixing board: every model's signal separately (camera +
  // meter + solo/mute) AND fused (the master bus + the drag), to spot the noise source.
  const [showDiagnostics, setShowDiagnostics] = useState(false);
  const diagnosticsEvidence = buildDiagnosticsEvidence(gestureEvidence.current, headPointing);

  // The onboarding is engine-owned (its prompts run in this engine window), but it
  // must paint ON-SCREEN and receive clicks — not inside the off-screen,
  // click-through engine-host. Portal it to the overlay HUD root when that exists
  // (the real overlay window); fall back to inline for the browser/tests.
  const onboardingNode = showOnboarding ? (
    <PermissionsOnboarding
      report={report}
      isChecking={isChecking}
      onRequestCamera={requestCamera}
      onRequestMedia={requestMedia}
      onRequestScreenRecording={requestScreenRecording}
      onRecheck={recheck}
      onRelaunch={relaunchApp}
      onOpenSettings={openPrivacySettings}
      onDismiss={() => setOnboardingDismissed(true)}
    />
  ) : null;
  const onboardingRoot =
    typeof document !== "undefined" ? document.getElementById("overlay-onboarding-root") : null;

  return (
    <main className="dashboard">
      {onboardingNode &&
        (onboardingRoot ? createPortal(onboardingNode, onboardingRoot) : onboardingNode)}
      <header className="dashboard__header">
        <div>
          <h1 className="dashboard__brand">{APP_NAME}</h1>
          <p className="dashboard__tagline">Point. Speak. Supervise your agents.</p>
        </div>
        <div className="dashboard__header-actions">
          <button
            type="button"
            className="dashboard__diagnostics-toggle"
            onClick={() => setShowDiagnostics((shown) => !shown)}
          >
            {showDiagnostics ? "Hide diagnostics" : "Diagnostics"}
          </button>
          <button type="button" className="dashboard__overlay-toggle" onClick={toggleOverlay}>
            {overlayShown ? "Hide screen overlay" : "Show on screen"}
          </button>
        </div>
      </header>
      {showDiagnostics && <DiagnosticsScreen evidence={diagnosticsEvidence} />}
      <div className="dashboard__panels">
        <CameraPanel
          autoStart={hasTauriBackend()}
          rawPointerRef={rawHandRef}
          calibrationOverride={handCalibrationOverride}
          onGestureEvidence={(evidence) => {
            gestureEvidence.current = evidence;
          }}
          onOverlayPointer={(update) => {
            handPointerRef.current = update;
            emitOverlayPointer(update);
          }}
          onFrameEvidence={(evidence) => {
            handFrameEvidence.current = evidence;
            pushTimestamp(handTsRef);
            emitLiveFusion();
            emitSupervisor();
          }}
        />
        <ReadinessPanel report={report} />
        <PermissionsPanel
          report={report}
          isChecking={isChecking}
          onRecheck={recheck}
          onRequestMedia={() => {
            // Fire the OS camera + mic + speech prompts, then re-probe so the panel
            // reflects the new grants.
            void invoke("request_media_permissions").finally(() => recheck());
          }}
          onOpenSettings={(pane) => void invoke("open_privacy_settings", { pane })}
        />
        <SettingsPanel
          config={config}
          status={status}
          updateConfig={updateConfig}
          resetConfig={resetConfig}
        />
        <TranscriptPanel
          createStream={createStream}
          headPointer={config.headPointer}
          onFinalTranscript={(utterance) => {
            lastTranscriptRef.current = utterance.text;
            // While a step awaits approval, a spoken "approve"/"deny" resolves the
            // gate hands-off instead of starting a new command.
            const pending = cuaApproval.pending[0];
            if (pending) {
              const decision = parseApprovalUtterance(utterance.text);
              if (decision) {
                cuaApproval.decide(pending.id, decision);
                return;
              }
            }
            handleFinalTranscript(utterance);
          }}
          onStatusChange={setCaptureStatus}
        />
        <SessionsPanel session={session} auditEvents={auditEvents} />
        <CuaApprovalPanel
          pending={cuaApproval.pending}
          onApprove={(id) => cuaApproval.decide(id, "allow")}
          onDeny={(id) => cuaApproval.decide(id, "deny")}
        />
        <ClarificationPanel request={clarification} />
        <PlanPreviewPanel
          intent={intent}
          runResult={runResult}
          onApprove={approve}
          onReject={reject}
        />
      </div>
    </main>
  );
}
