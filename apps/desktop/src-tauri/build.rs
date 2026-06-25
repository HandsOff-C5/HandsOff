use std::env;
use std::path::Path;
use std::process::Command;

fn main() {
    bake_local_worker_config();
    // Compile the native permissions bridge (#31). macOS-only; the app targets macOS.
    #[cfg(target_os = "macos")]
    {
        build_native_permissions_bridge();
    }
    tauri_build::build()
}

// Dev convenience: bake the `HANDSOFF_*` worker config (Worker URLs + app-cohort
// tokens) from `apps/desktop/.env.local` into the binary at compile time, so every
// launch is fully wired without launch-time `--env` flags. The runtime env still
// overrides (see `commands::deployment_config`). Only `HANDSOFF_*` keys are baked —
// never the provider API keys (`OPENAI_API_KEY`/`ASSEMBLYAI_API_KEY`), which live
// solely in the deployed Workers. A release build on a machine without `.env.local`
// bakes nothing and falls back to runtime env — provider-secret-free by default.
fn bake_local_worker_config() {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let env_path = format!("{manifest}/../.env.local");
    println!("cargo:rerun-if-changed={env_path}");
    let Ok(contents) = std::fs::read_to_string(&env_path) else {
        return;
    };
    for line in contents.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if !key.starts_with("HANDSOFF_") {
            continue;
        }
        let value = value.trim().trim_matches('"').trim_matches('\'');
        println!("cargo:rustc-env={key}={value}");
    }
}

#[cfg(target_os = "macos")]
fn build_native_permissions_bridge() {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let src = format!("{manifest}/src/native_permissions.m");
    println!("cargo:rerun-if-changed={src}");

    let speech_analyzer = speech_analyzer_bridge_if_available(manifest);
    let mut build = cc::Build::new();
    build.file(&src).flag("-fobjc-arc");
    if speech_analyzer.is_some() {
        build.define("HANDSOFF_HAS_SPEECHANALYZER", "1");
    }
    build.compile("handsoff_native_permissions");
    if let Some(speech_analyzer) = speech_analyzer {
        build_speech_analyzer_bridge(speech_analyzer);
    }

    // The `fn` (Globe) capture trigger (#95) is observed directly with a
    // listen-only CGEventTap in src/commands/hotkey.rs; CoreGraphics and
    // CoreFoundation are linked from that file via per-callsite #[link].

    println!("cargo:rustc-link-lib=framework=AVFoundation");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=Speech");
}

#[cfg(target_os = "macos")]
struct SpeechAnalyzerBridge {
    src: String,
    sdk_path: String,
    target: String,
    out_dir: String,
    lib_path: String,
}

#[cfg(target_os = "macos")]
fn speech_analyzer_bridge_if_available(manifest: &str) -> Option<SpeechAnalyzerBridge> {
    let src = format!("{manifest}/src/speechanalyzer_bridge.swift");
    println!("cargo:rerun-if-changed={src}");

    let sdk_major = macos_sdk_major_version()?;
    if sdk_major < 26 {
        return None;
    }

    let out_dir = env::var("OUT_DIR").expect("OUT_DIR is set by cargo");
    let lib_path = format!("{out_dir}/libhandsoff_speechanalyzer.a");
    let sdk_path = macos_sdk_path().or_else(|| {
        println!("cargo:warning=macOS 26 SDK version found but SDK path was unavailable; using SFSpeechRecognizer fallback");
        None
    })?;
    let target = swift_target();

    Some(SpeechAnalyzerBridge {
        src,
        sdk_path,
        target,
        out_dir,
        lib_path,
    })
}

#[cfg(target_os = "macos")]
fn build_speech_analyzer_bridge(bridge: SpeechAnalyzerBridge) {
    let status = Command::new("xcrun")
        .args([
            "swiftc",
            "-sdk",
            &bridge.sdk_path,
            "-target",
            &bridge.target,
            "-parse-as-library",
            "-emit-library",
            "-static",
            "-o",
            &bridge.lib_path,
            &bridge.src,
        ])
        .status()
        .expect("failed to invoke swiftc for SpeechAnalyzer bridge");

    if !status.success() {
        panic!("swiftc failed to compile SpeechAnalyzer bridge");
    }

    println!("cargo:rustc-link-search=native={}", bridge.out_dir);
    println!("cargo:rustc-link-lib=static=handsoff_speechanalyzer");
    if let Some(swift_lib_path) = swift_runtime_library_path() {
        println!("cargo:rustc-link-search=native={swift_lib_path}");
        println!("cargo:rustc-link-arg=-Wl,-rpath,{swift_lib_path}");
    }
}

#[cfg(target_os = "macos")]
fn macos_sdk_major_version() -> Option<u32> {
    let output = Command::new("xcrun")
        .args(["--sdk", "macosx", "--show-sdk-version"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let version = String::from_utf8(output.stdout).ok()?;
    version.trim().split('.').next()?.parse().ok()
}

#[cfg(target_os = "macos")]
fn macos_sdk_path() -> Option<String> {
    let output = Command::new("xcrun")
        .args(["--sdk", "macosx", "--show-sdk-path"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8(output.stdout).ok()?.trim().to_string())
}

#[cfg(target_os = "macos")]
fn swift_target() -> String {
    let arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_else(|_| "aarch64".to_string());
    match arch.as_str() {
        "x86_64" => "x86_64-apple-macosx11.0".to_string(),
        _ => "arm64-apple-macosx11.0".to_string(),
    }
}

#[cfg(target_os = "macos")]
fn swift_runtime_library_path() -> Option<String> {
    let output = Command::new("xcrun")
        .args(["--find", "swiftc"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let swiftc = String::from_utf8(output.stdout).ok()?;
    let toolchain = Path::new(swiftc.trim()).ancestors().nth(3)?;
    Some(
        toolchain
            .join("usr/lib/swift/macosx")
            .to_string_lossy()
            .into_owned(),
    )
}
