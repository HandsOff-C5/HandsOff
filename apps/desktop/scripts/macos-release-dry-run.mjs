#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const desktopRoot = resolve(scriptDir, "..");
const appName = "HandsOff";
const appBundlePath = "src-tauri/target/debug/bundle/macos/HandsOff.app";
const log = (message) => process.stdout.write(`${message}\n`);
const warn = (message) => process.stderr.write(`${message}\n`);

const entitlementPermissions = [
  {
    capability: "camera",
    mechanism: "entitlement",
    entitlementKey: "com.apple.security.device.camera",
    usageDescription: "NSCameraUsageDescription",
  },
  {
    capability: "microphone",
    mechanism: "entitlement",
    entitlementKey: "com.apple.security.device.audio-input",
    usageDescription: "NSMicrophoneUsageDescription",
  },
  {
    capability: "speech recognition",
    mechanism: "entitlement",
    entitlementKey: "com.apple.security.personal-information.speech-recognition",
    usageDescription: "NSSpeechRecognitionUsageDescription",
  },
];

const tccPermissions = [
  {
    capability: "screen recording",
    mechanism: "TCC user grant",
    validation: "CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess prompt path",
  },
  {
    capability: "accessibility",
    mechanism: "TCC user grant",
    validation: "Accessibility grant for the CUA driver; no app entitlement exists",
  },
];

function readProjectFile(relativePath) {
  return readFileSync(join(desktopRoot, relativePath), "utf8");
}

function hasPlistKey(plist, key) {
  return plist.includes(`<key>${key}</key>`);
}

function dryRunPlan() {
  const config = JSON.parse(readProjectFile("src-tauri/tauri.conf.json"));
  const entitlementsPath = config.bundle?.macOS?.entitlements ?? "";
  const entitlements = entitlementsPath ? readProjectFile(join("src-tauri", entitlementsPath)) : "";
  const info = readProjectFile("src-tauri/Info.plist");
  const signingIdentity = config.bundle?.macOS?.signingIdentity ?? null;

  const permissions = [
    ...entitlementPermissions.map((permission) => ({
      ...permission,
      present:
        Boolean(
          permission.entitlementKey && hasPlistKey(entitlements, permission.entitlementKey),
        ) && hasPlistKey(info, permission.usageDescription),
    })),
    ...tccPermissions.map((permission) => ({ ...permission, present: true })),
  ];

  const checks = [
    {
      name: "bundle identifier",
      expected: "com.handsoff.desktop",
      actual: config.identifier,
      ok: config.identifier === "com.handsoff.desktop",
    },
    {
      name: "macOS signing identity",
      expected: "configured",
      actual: signingIdentity,
      ok: typeof signingIdentity === "string" && signingIdentity.length > 0,
    },
    {
      name: "macOS entitlements file",
      expected: "src-tauri/entitlements.plist",
      actual: entitlementsPath ? `src-tauri/${entitlementsPath}` : null,
      ok: entitlementsPath === "entitlements.plist",
    },
    ...permissions.map((permission) => ({
      name: `${permission.capability} permission review`,
      expected: permission.mechanism,
      actual: permission.present ? permission.mechanism : "missing",
      ok: permission.present,
    })),
  ];

  return {
    app: appName,
    bundleIdentifier: config.identifier,
    appBundlePath,
    signing: {
      identity: signingIdentity,
      entitlements: entitlementsPath,
      command: ["pnpm", "tauri", "build", "--debug", "--bundles", "app"],
      validation: [
        `codesign --verify --deep --strict --verbose=2 ${appBundlePath}`,
        `codesign -dvvv --entitlements :- ${appBundlePath}`,
      ],
    },
    notarization: {
      archiveCommand: ["ditto", "-c", "-k", "--keepParent", appBundlePath, "HandsOff.zip"],
      submitCommand: [
        "xcrun",
        "notarytool",
        "submit",
        "HandsOff.zip",
        "--keychain-profile",
        "<external-profile>",
        "--wait",
      ],
      validation: [
        "xcrun notarytool history --keychain-profile <external-profile>",
        `spctl -a -vv ${appBundlePath}`,
      ],
      credentialSource: "external keychain profile or CI secret",
    },
    permissions,
    checks,
  };
}

function failedChecks(plan) {
  return plan.checks.filter((check) => !check.ok);
}

function validateConfig() {
  const plan = dryRunPlan();
  const failures = failedChecks(plan);
  if (failures.length > 0) {
    warn("macOS release dry-run config failed:");
    for (const failure of failures) {
      warn(`- ${failure.name}: expected ${failure.expected}, got ${failure.actual}`);
    }
    process.exitCode = 1;
    return;
  }

  log(`macOS release dry-run config ok for ${plan.bundleIdentifier}`);
  log(`Signing identity: ${plan.signing.identity}`);
  log(`Dry-run build: ${plan.signing.command.join(" ")}`);
  log(`Notarization validation: ${plan.notarization.validation.join(" && ")}`);
}

function validateApp(appPath) {
  validateConfig();
  if (process.exitCode) return;

  const resolvedAppPath = resolve(desktopRoot, appPath);
  const mainBinary = join(resolvedAppPath, "Contents", "MacOS", appName);
  if (!existsSync(resolvedAppPath) || !statSync(resolvedAppPath).isDirectory()) {
    warn(`app bundle not found: ${resolvedAppPath}`);
    process.exitCode = 1;
    return;
  }
  if (!existsSync(mainBinary)) {
    warn(`main binary not found: ${mainBinary}`);
    process.exitCode = 1;
    return;
  }

  execFileSync("codesign", ["--verify", "--deep", "--strict", "--verbose=2", resolvedAppPath], {
    stdio: "inherit",
  });
  execFileSync("codesign", ["-dvvv", "--entitlements", ":-", resolvedAppPath], {
    stdio: "inherit",
  });
  log(`app bundle signing validation ok: ${resolvedAppPath}`);
}

const args = process.argv.slice(2);
if (args.includes("--json")) {
  log(JSON.stringify(dryRunPlan(), null, 2));
} else if (args[0] === "--validate-app" && args[1]) {
  validateApp(args[1]);
} else if (args.length === 0 || args.includes("--validate-config")) {
  validateConfig();
} else {
  warn("usage: macos-release-dry-run.mjs [--json|--validate-config|--validate-app <app>]");
  process.exitCode = 64;
}
