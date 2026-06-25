import {
  APP_NAME,
  type CapabilityId,
  type PointingEvidence,
  type SttProvider,
  type SttStream,
} from "@handsoff/contracts";
import { createTauriCuaDriver, createUnavailableCuaDriver, type CuaDriver } from "@handsoff/cua";
import { planPermissionOnboarding } from "@handsoff/desktop";
import { createAssemblyAiStream, createOnDeviceSttStream } from "@handsoff/speech";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useRef, useState } from "react";

import { CameraPanel } from "../../features/camera/CameraPanel";
import { ClarificationPanel } from "../../features/clarification/ClarificationPanel";
import { PermissionsOnboarding } from "../../features/permissions/PermissionsOnboarding";
import { PermissionsPanel } from "../../features/permissions/PermissionsPanel";
import { PlanPreviewPanel } from "../../features/plan-preview/PlanPreviewPanel";
import { ReadinessPanel } from "../../features/readiness/ReadinessPanel";
import { ReferentsPanel } from "../../features/referents/ReferentsPanel";
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
import {
  createIntentWorkerResolver,
  useVoiceCuaController,
} from "../../features/voice-cua/useVoiceCuaController";
import type { ResolveIntentOptions } from "@handsoff/intent";
import type { IntentInput, ResolvedIntent } from "@handsoff/contracts";
import type { SupervisionSession } from "@handsoff/supervision";

function hasTauriBackend(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

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
  // Latest gesture cursor position (even without a locked referent). Updated every
  // frame while hands are present, cleared to null when no hands are detected.
  const gestureCursor = useRef<{ x: number; y: number } | null>(null);
  const intentResolver =
    resolveIntent ??
    (hasTauriBackend()
      ? createIntentWorkerResolver((command, args) => invoke(command, args))
      : undefined);
  const liveHeadPointing = useHeadPointing(hasTauriBackend() ? HEAD_POINTING_TAURI : undefined);
  const headPointing = injectedHeadPointing ?? liveHeadPointing;
  const { intent, runResult, session, auditEvents, approve, reject, handleFinalTranscript } =
    useVoiceCuaController({
      driver,
      headPointing,
      now,
      resolveIntent: intentResolver,
      targetResolveDelayMs,
      getGestureEvidence: () => gestureEvidence.current,
      getGestureCursor: () => gestureCursor.current,
    });
  // Accumulate session history (last 10) so the SessionsPanel shows prior commands
  // rather than only the most-recent run.
  const [sessionHistory, setSessionHistory] = useState<readonly SupervisionSession[]>([]);
  useEffect(() => {
    if (!session) return;
    setSessionHistory((prev) => {
      // Avoid duplicates: replace if id already exists (status update), else append.
      const idx = prev.findIndex((s) => s.id === session.id);
      if (idx !== -1) {
        return [...prev.slice(0, idx), session, ...prev.slice(idx + 1)];
      }
      return [...prev, session].slice(-10);
    });
  }, [session]);
  // The structured clarification prompt (#36) when the engine won't act blind.
  // Display-first; interactive pick→re-resolve needs a controller round-trip (follow-up).
  const clarification =
    intent?.status === "clarification_required" ? (intent.clarification ?? null) : null;

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

  return (
    <main className="dashboard">
      {showOnboarding && (
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
      )}
      <header className="dashboard__header">
        <div>
          <h1 className="dashboard__brand">{APP_NAME}</h1>
          <p className="dashboard__tagline">Point. Speak. Supervise your agents.</p>
        </div>
        <button type="button" className="dashboard__overlay-toggle" onClick={toggleOverlay}>
          {overlayShown ? "Hide screen overlay" : "Show on screen"}
        </button>
      </header>
      <div className="dashboard__panels">
        <CameraPanel
          autoStart
          onGestureEvidence={(evidence) => {
            gestureEvidence.current = evidence;
          }}
          onGestureCursor={(cursor) => {
            gestureCursor.current = cursor;
          }}
        />
        <ReferentsPanel intent={intent} />
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
          onFinalTranscript={handleFinalTranscript}
        />
        <SessionsPanel sessions={sessionHistory} auditEvents={auditEvents} />
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
