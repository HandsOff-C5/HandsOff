import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const MEDIA_ENTITLEMENTS = [
  "com.apple.security.device.audio-input",
  "com.apple.security.personal-information.speech-recognition",
] as const;

function readDesktopFile(relativePath: string): string {
  const workspacePath = join(process.cwd(), "apps/desktop", relativePath);
  const desktopPath = join(process.cwd(), relativePath);
  return readFileSync(existsSync(workspacePath) ? workspacePath : desktopPath, "utf8");
}

describe("macOS media permission signing config", () => {
  it("signs the app bundle with the stable identity and media entitlements", () => {
    const config = JSON.parse(readDesktopFile("src-tauri/tauri.conf.json")) as {
      identifier?: string;
      bundle?: { macOS?: { entitlements?: string; signingIdentity?: string } };
    };

    expect(config.identifier).toBe("com.handsoff.desktop");
    expect(config.bundle?.macOS?.signingIdentity).toBe("-");
    expect(config.bundle?.macOS?.entitlements).toBe("entitlements.plist");

    const entitlements = readDesktopFile("src-tauri/entitlements.plist");
    for (const key of MEDIA_ENTITLEMENTS) {
      expect(entitlements).toContain(`<key>${key}</key>`);
    }
  });

  it("keeps the STT sidecar signed for microphone capture and speech recognition", () => {
    const entitlements = readDesktopFile("src-tauri/sidecars/stt-ondevice/entitlements.plist");

    for (const key of MEDIA_ENTITLEMENTS) {
      expect(entitlements).toContain(`<key>${key}</key>`);
    }
  });

  it("runs live on-device STT in the app process that owns the Speech permission", () => {
    const command = readDesktopFile("src-tauri/src/commands/stt_ondevice.rs");
    const bridge = readDesktopFile("src-tauri/src/native_permissions.m");

    expect(command).toContain("handsoff_stt_start");
    expect(command).not.toContain(".sidecar(SIDECAR_NAME)");
    expect(bridge).toContain("SFSpeechAudioBufferRecognitionRequest");
    expect(bridge).toContain("AVAudioEngine");
  });
});
