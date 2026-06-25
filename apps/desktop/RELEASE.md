# macOS signing and notarization dry run

HandsOff exercises the distribution path with an ad hoc signed debug app bundle before real certificates or notarization credentials are available. This catches bundle structure, signing identity, sidecar, and entitlement drift without storing certificates, passwords, API keys, or profile material in this repo.

## Local dry run

From the repository root:

```bash
corepack pnpm --filter @handsoff/desktop-app release:dry-run
```

The command runs:

1. `pnpm tauri build --debug --bundles app`
2. `node scripts/macos-release-dry-run.mjs --validate-app src-tauri/target/debug/bundle/macos/HandsOff.app`

The Tauri config signs the macOS bundle with the configured signing path in `apps/desktop/src-tauri/tauri.conf.json`:

```json
{
  "bundle": {
    "macOS": {
      "entitlements": "entitlements.plist",
      "signingIdentity": "-"
    }
  }
}
```

`-` is Apple codesign's ad hoc identity. It is suitable for local dry-run validation, not distribution.

For a lightweight review without building the app bundle:

```bash
corepack pnpm --filter @handsoff/desktop-app release:dry-run:plan
```

## Validation commands

When the dry-run bundle exists at `apps/desktop/src-tauri/target/debug/bundle/macos/HandsOff.app`, validate signing and entitlements directly:

```bash
codesign --verify --deep --strict --verbose=2 apps/desktop/src-tauri/target/debug/bundle/macos/HandsOff.app
codesign -dvvv --entitlements :- apps/desktop/src-tauri/target/debug/bundle/macos/HandsOff.app
```

Gatekeeper distribution validation is separate from local debug signing:

```bash
spctl -a -vv apps/desktop/src-tauri/target/debug/bundle/macos/HandsOff.app
```

An ad hoc signed debug bundle is expected to fail full distribution trust. That is not a local build failure.

## Notarization path

Real notarization needs a Developer ID signed archive and credentials supplied outside the repo, either via a keychain profile on a local Mac or CI secrets. No certificates, passwords, API keys, or profile material belong in this repo.

Once a Developer ID signed app exists:

```bash
ditto -c -k --keepParent apps/desktop/src-tauri/target/debug/bundle/macos/HandsOff.app HandsOff.zip
xcrun notarytool submit HandsOff.zip --keychain-profile <external-profile> --wait
xcrun stapler staple apps/desktop/src-tauri/target/debug/bundle/macos/HandsOff.app
spctl -a -vv apps/desktop/src-tauri/target/debug/bundle/macos/HandsOff.app
```

To validate available credentials without committing them:

```bash
xcrun notarytool history --keychain-profile <external-profile>
```

## Permission review

HandsOff needs these macOS capabilities for the core loop:

| Capability | Mechanism | Committed review source |
| --- | --- | --- |
| Camera | Entitlement + usage description | `com.apple.security.device.camera`, `NSCameraUsageDescription` |
| Microphone | Entitlement + usage description | `com.apple.security.device.audio-input`, `NSMicrophoneUsageDescription` |
| Speech Recognition | Entitlement + usage description | `com.apple.security.personal-information.speech-recognition`, `NSSpeechRecognitionUsageDescription` |
| Screen Recording | TCC user grant | Prompt/readiness path; no app entitlement exists |
| Accessibility | TCC user grant | CUA driver grant; no app entitlement exists |

Screen Recording and Accessibility are reviewed as TCC grants, not entitlements. The dry-run validator lists them so release rehearsal does not confuse "missing entitlement" with "user must grant this in System Settings."
