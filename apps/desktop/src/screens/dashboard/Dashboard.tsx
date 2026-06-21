import { APP_NAME, type SttStream } from "@handsoff/contracts";
import { createAssemblyAiStream } from "@handsoff/speech";
import { invoke } from "@tauri-apps/api/core";

import { PermissionsPanel } from "../../features/permissions/PermissionsPanel";
import { PlanPreviewPanel } from "../../features/plan-preview/PlanPreviewPanel";
import { ReadinessPanel } from "../../features/readiness/ReadinessPanel";
import { useReadinessProbe } from "../../features/readiness/useReadinessProbe";
import { SessionsPanel } from "../../features/sessions/SessionsPanel";
import { SettingsPanel } from "../../features/settings/SettingsPanel";
import { TranscriptPanel } from "../../features/transcript/TranscriptPanel";

function hasTauriBackend(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

// Build a live AssemblyAI stream whose token is minted host-side (#31), so the
// API key never reaches the webview. Only available with a native backend; in a
// browser/jsdom context the transcript panel shows its unavailable state.
function createLiveSttStream(): SttStream {
  return createAssemblyAiStream({
    tokenProvider: async () => {
      const result = await invoke<{ token: string }>("stt_mint_token", { expiresInSeconds: 60 });
      return result.token;
    },
  });
}

// Mission-control dashboard shell (issue #15). Branded header plus one panel per
// core-loop concern. Readiness (#17) and permission education (#18) share one
// host probe: the readiness panel shows status at a glance, the permissions panel
// turns missing macOS grants into targeted setup steps and a re-check. The
// transcript panel (#31) turns speech into visible partial/final transcripts.
export function Dashboard() {
  const { report, isChecking, recheck } = useReadinessProbe();
  const createStream = hasTauriBackend() ? createLiveSttStream : undefined;
  return (
    <main className="dashboard">
      <header className="dashboard__header">
        <h1 className="dashboard__brand">{APP_NAME}</h1>
        <p className="dashboard__tagline">Point. Speak. Supervise your agents.</p>
      </header>
      <div className="dashboard__panels">
        <ReadinessPanel report={report} />
        <PermissionsPanel report={report} isChecking={isChecking} onRecheck={recheck} />
        <SettingsPanel />
        <TranscriptPanel createStream={createStream} />
        <SessionsPanel />
        <PlanPreviewPanel />
      </div>
    </main>
  );
}
