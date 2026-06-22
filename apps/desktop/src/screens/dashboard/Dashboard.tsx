import { runApprovedPlan, type CuaActionPort, type PlanRunResult } from "@handsoff/actions";
import {
  APP_NAME,
  type CuaActionRequest,
  type FinalTranscript,
  type SttProvider,
  type SttStream,
  type SurfaceSnapshot,
} from "@handsoff/contracts";
import { createTauriCuaDriver, createUnavailableCuaDriver, type CuaDriver } from "@handsoff/cua";
import { createAssemblyAiStream, createOnDeviceSttStream } from "@handsoff/speech";
import { fuseIntent } from "@handsoff/intent";
import { createActionAuditStore } from "@handsoff/supervision";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useRef, useState } from "react";

import { PermissionsPanel } from "../../features/permissions/PermissionsPanel";
import { PlanPreviewPanel } from "../../features/plan-preview/PlanPreviewPanel";
import { ReadinessPanel } from "../../features/readiness/ReadinessPanel";
import { useReadinessProbe } from "../../features/readiness/useReadinessProbe";
import { SessionsPanel } from "../../features/sessions/SessionsPanel";
import { SettingsPanel } from "../../features/settings/SettingsPanel";
import { useLocalConfig } from "../../features/settings/useLocalConfig";
import { TranscriptPanel } from "../../features/transcript/TranscriptPanel";
import { makeApprovalDecision } from "../../features/plan-preview/usePlanApproval";

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

// "Realtime" mode: hosted streaming whose token is minted host-side so the key
// never reaches the webview. Needs a provisioned key (dev: env; prod: the
// fast-follow Cloudflare Worker); without one it surfaces a recoverable error.
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

const ACTIVE_WINDOW_SURFACE: SurfaceSnapshot = {
  id: "active-window",
  title: "Active window",
  app: "Current app",
  availability: "available",
  accessStatus: "accessible",
};

function actionPortFor(driver: CuaDriver): CuaActionPort {
  return {
    getWindowState: ({ target }: Extract<CuaActionRequest, { kind: "get_window_state" }>) =>
      driver.getWindowState(target),
    click: ({ target }: Extract<CuaActionRequest, { kind: "click" }>) => driver.click(target),
    typeText: ({ target, text }: Extract<CuaActionRequest, { kind: "type_text" }>) =>
      driver.typeText(target, text),
    setValue: ({ target, value }: Extract<CuaActionRequest, { kind: "set_value" }>) =>
      driver.setValue(target, value),
    screenshot: ({ target }: Extract<CuaActionRequest, { kind: "screenshot" }>) =>
      driver.screenshot(target),
  };
}

interface DashboardProps {
  createStream?: () => SttStream;
  cuaDriver?: CuaDriver;
  now?: () => string;
}

// Mission-control dashboard shell (issue #15). Branded header plus one panel per
// core-loop concern. Readiness (#17) and permission education (#18) share one
// host probe: the readiness panel shows status at a glance, the permissions panel
// turns missing macOS grants into targeted setup steps and a re-check. The
// transcript panel (#31) turns speech into visible partial/final transcripts.
export function Dashboard({ createStream: injectedStream, cuaDriver, now }: DashboardProps = {}) {
  const { report, isChecking, recheck } = useReadinessProbe();
  const { config, status, updateConfig, resetConfig } = useLocalConfig();
  const [intent, setIntent] = useState<ReturnType<typeof fuseIntent> | null>(null);
  const [runResult, setRunResult] = useState<PlanRunResult | null>(null);
  const audit = useRef(createActionAuditStore());
  const createStream =
    injectedStream ?? (hasTauriBackend() ? streamFactoryFor(config.sttProvider) : undefined);
  const driver =
    cuaDriver ??
    (hasTauriBackend()
      ? createTauriCuaDriver((command, args) => invoke(command, args))
      : createUnavailableCuaDriver());
  const timestamp = () => now?.() ?? new Date().toISOString();

  function handleFinalTranscript(finalTranscript: FinalTranscript) {
    void createIntent(finalTranscript);
  }

  async function createIntent(finalTranscript: FinalTranscript) {
    const resolved = await driver.getWindowState({ surface: ACTIVE_WINDOW_SURFACE });
    const surface =
      resolved.status === "succeeded" && resolved.state
        ? resolved.state.surface
        : {
            ...ACTIVE_WINDOW_SURFACE,
            availability: "unknown" as const,
            accessStatus: "unknown" as const,
          };
    const next = fuseIntent(
      {
        sessionId: "session-1",
        speech: { finalTranscript },
        pointingEvidence: [
          {
            source: "cursor",
            confidence: 1,
            strategy: "active-window-current-cursor",
            surface,
          },
        ],
        surfaceCandidates: [surface],
      },
      { createdAt: timestamp() },
    );
    setIntent(next);
    setRunResult(null);
    audit.current.record({
      kind: "intent_created",
      sessionId: "session-1",
      actionId: next.status === "ready" ? next.action_plan.id : next.id,
      recordedAt: timestamp(),
      intent: next,
    });
  }

  async function approve() {
    if (intent?.status !== "ready") return;
    setRunResult({ status: "running" });
    const result = await runApprovedPlan({
      sessionId: "session-1",
      plan: intent.action_plan,
      approval: makeApprovalDecision(intent.action_plan.id, "approved", timestamp()),
      cua: actionPortFor(driver),
      audit: audit.current,
      recordedAt: timestamp(),
    });
    setRunResult(result);
  }

  function reject() {
    if (intent?.status !== "ready") return;
    const decision = makeApprovalDecision(intent.action_plan.id, "rejected", timestamp());
    audit.current.record({
      kind: "approval_decided",
      sessionId: "session-1",
      actionId: intent.action_plan.id,
      recordedAt: timestamp(),
      approval: decision,
    });
    setRunResult({ status: "rejected" });
  }

  return (
    <main className="dashboard">
      <header className="dashboard__header">
        <h1 className="dashboard__brand">{APP_NAME}</h1>
        <p className="dashboard__tagline">Point. Speak. Supervise your agents.</p>
      </header>
      <div className="dashboard__panels">
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
        <SessionsPanel status={runResult?.status} />
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
