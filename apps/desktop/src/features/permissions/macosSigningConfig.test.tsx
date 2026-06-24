import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const MEDIA_ENTITLEMENTS = [
  "com.apple.security.device.camera",
  "com.apple.security.device.audio-input",
  "com.apple.security.personal-information.speech-recognition",
] as const;

function readDesktopFile(relativePath: string): string {
  const workspacePath = join(process.cwd(), "apps/desktop", relativePath);
  const desktopPath = join(process.cwd(), relativePath);
  return readFileSync(existsSync(workspacePath) ? workspacePath : desktopPath, "utf8");
}

function desktopPath(relativePath: string): string {
  const workspacePath = join(process.cwd(), "apps/desktop", relativePath);
  const desktopPath = join(process.cwd(), relativePath);
  return existsSync(workspacePath) ? workspacePath : desktopPath;
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

  it("runs live on-device STT in the app process that owns the Speech permission", () => {
    const command = readDesktopFile("src-tauri/src/commands/stt_ondevice.rs");
    const bridge = readDesktopFile("src-tauri/src/native_permissions.m");

    expect(command).toContain("handsoff_stt_start");
    expect(command).not.toContain(".sidecar(SIDECAR_NAME)");
    expect(bridge).toContain("SFSpeechAudioBufferRecognitionRequest");
    expect(bridge).toContain("AVAudioEngine");
  });

  it("defines local macOS release dry-run entrypoints", () => {
    const pkg = JSON.parse(readDesktopFile("package.json")) as {
      scripts?: Record<string, string>;
    };

    expect(pkg.scripts?.["release:dry-run"]).toBe(
      "pnpm tauri build --debug --bundles app && node scripts/macos-release-dry-run.mjs --validate-app src-tauri/target/debug/bundle/macos/HandsOff.app",
    );
    expect(pkg.scripts?.["release:dry-run:plan"]).toBe(
      "node scripts/macos-release-dry-run.mjs --json",
    );
  });

  it("prints a signing and notarization dry-run plan without repository credentials", () => {
    const output = execFileSync(
      process.execPath,
      [desktopPath("scripts/macos-release-dry-run.mjs"), "--json"],
      {
        encoding: "utf8",
      },
    );
    const plan = JSON.parse(output) as {
      signing: { identity: string; command: readonly string[] };
      notarization: { validation: readonly string[]; credentialSource: string };
      permissions: readonly { capability: string; mechanism: string; entitlementKey?: string }[];
    };

    expect(plan.signing.identity).toBe("-");
    expect(plan.signing.command).toEqual(["pnpm", "tauri", "build", "--debug", "--bundles", "app"]);
    expect(plan.notarization.validation).toContain(
      "xcrun notarytool history --keychain-profile <external-profile>",
    );
    expect(plan.notarization.credentialSource).toBe("external keychain profile or CI secret");
    expect(plan.permissions).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          capability: "camera",
          mechanism: "entitlement",
          entitlementKey: "com.apple.security.device.camera",
        }),
        expect.objectContaining({
          capability: "microphone",
          mechanism: "entitlement",
          entitlementKey: "com.apple.security.device.audio-input",
        }),
        expect.objectContaining({
          capability: "speech recognition",
          mechanism: "entitlement",
          entitlementKey: "com.apple.security.personal-information.speech-recognition",
        }),
        expect.objectContaining({
          capability: "screen recording",
          mechanism: "TCC user grant",
        }),
        expect.objectContaining({
          capability: "accessibility",
          mechanism: "TCC user grant",
        }),
      ]),
    );
  });

  it("documents the notarization dry-run path and reviewed permission model", () => {
    const doc = readDesktopFile("RELEASE.md");

    expect(doc).toContain("pnpm --filter @handsoff/desktop-app release:dry-run");
    expect(doc).toContain("xcrun notarytool submit");
    expect(doc).toContain("Screen Recording");
    expect(doc).toContain("Accessibility");
    expect(doc).toContain(
      "No certificates, passwords, API keys, or profile material belong in this repo.",
    );
  });
});
