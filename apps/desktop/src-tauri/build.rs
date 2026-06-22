use std::env;
use std::path::Path;
use std::process::Command;

fn main() {
    // Compile the native permissions bridge (#31). macOS-only; the app targets macOS.
    #[cfg(target_os = "macos")]
    {
        build_native_permissions_bridge();
    }
    tauri_build::build()
}

#[cfg(target_os = "macos")]
fn build_native_permissions_bridge() {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let src = format!("{manifest}/src/native_permissions.m");
    println!("cargo:rerun-if-changed={src}");

    cc::Build::new()
        .file(&src)
        .flag("-fobjc-arc")
        .compile("handsoff_native_permissions");
    build_speech_analyzer_bridge_if_available(manifest);
    println!("cargo:rustc-link-lib=framework=AVFoundation");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=Speech");
}

#[cfg(target_os = "macos")]
fn build_speech_analyzer_bridge_if_available(manifest: &str) {
    let src = format!("{manifest}/src/speechanalyzer_bridge.swift");
    println!("cargo:rerun-if-changed={src}");

    let Some(sdk_major) = macos_sdk_major_version() else {
        return;
    };
    if sdk_major < 26 {
        return;
    }

    let out_dir = env::var("OUT_DIR").expect("OUT_DIR is set by cargo");
    let lib_path = format!("{out_dir}/libhandsoff_speechanalyzer.a");
    let sdk_path =
        macos_sdk_path().expect("macOS SDK path should exist when SDK version was found");
    let target = swift_target();

    let status = Command::new("xcrun")
        .args([
            "swiftc",
            "-sdk",
            &sdk_path,
            "-target",
            &target,
            "-parse-as-library",
            "-emit-library",
            "-static",
            "-o",
            &lib_path,
            &src,
        ])
        .status()
        .expect("failed to invoke swiftc for SpeechAnalyzer bridge");

    if !status.success() {
        panic!("swiftc failed to compile SpeechAnalyzer bridge");
    }

    println!("cargo:rustc-link-search=native={out_dir}");
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
