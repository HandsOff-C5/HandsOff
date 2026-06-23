import {
  APP_NAME,
  type PointingEvidence,
  type SttProvider,
  type SttStream,
} from "@handsoff/contracts";
import { createTauriCuaDriver, createUnavailableCuaDriver, type CuaDriver } from "@handsoff/cua";
import { createAssemblyAiStream, createOnDeviceSttStream } from "@handsoff/speech";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useRef } from "react";

import { CameraPanel } from "../../features/camera/CameraPanel";
import { ClarificationPanel } from "../../features/clarification/ClarificationPanel";
import { PermissionsPanel } from "../../features/permissions/PermissionsPanel";
import { PlanPreviewPanel } from "../../features/plan-preview/PlanPreviewPanel";
import { ReadinessPanel } from "../../features/readiness/ReadinessPanel";
import { useReadinessProbe } from "../../features/readiness/useReadinessProbe";
import { SessionsPanel } from "../../features/sessions/SessionsPanel";
import { SettingsPanel } from "../../features/settings/SettingsPanel";
import { useLocalConfig } from "../../features/settings/useLocalConfig";
import { TranscriptPanel } from "../../features/transcript/TranscriptPanel";
import { useVoiceCuaController } from "../../features/voice-cua/useVoiceCuaController";

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

// The transcription mode the user picked in Settings decides which provider the
// transcript panel speaks to. Both satisfy the same `SttStream` seam, so the
// panel and intent engine are unchanged.
function streamFactoryFor(provider: SttProvider): () => SttStream {
  return provider === "assemblyai" ? createRealtimeStream : createOnDeviceStream;
}

interface DashboardProps {
  createStream?: () => SttStream;
  cuaDriver?: CuaDriver;
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
  const { intent, runResult, session, approve, reject, handleFinalTranscript } =
    useVoiceCuaController({
      driver,
      now,
      targetResolveDelayMs,
      getGestureEvidence: () => gestureEvidence.current,
    });
  // The structured clarification prompt (#36) when the engine won't act blind.
  // Display-first; interactive pick→re-resolve needs a controller round-trip (follow-up).
  const clarification =
    intent?.status === "clarification_required" ? (intent.clarification ?? null) : null;

  return (
    <main className="dashboard">
      <header className="dashboard__header">
        <h1 className="dashboard__brand">{APP_NAME}</h1>
        <p className="dashboard__tagline">Point. Speak. Supervise your agents.</p>
      </header>
      <div className="dashboard__panels">
        <CameraPanel
          onGestureEvidence={(evidence) => {
            gestureEvidence.current = evidence;
          }}
        />
        <ReadinessPanel report={report} />
        <PermissionsPanel
          report={report}
          isChecking={isChecking}
          onRecheck={recheck}
          onRequestMedia={() => {
            // Fire the OS mic + speech prompts, then re-probe so the panel
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
        <TranscriptPanel createStream={createStream} onFinalTranscript={handleFinalTranscript} />
        <SessionsPanel session={session} />
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
