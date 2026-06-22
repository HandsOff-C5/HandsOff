fn main() {
    // Compile the on-device STT Swift sidecar (#31) into the location Tauri's
    // `externalBin` resolver expects. macOS-only; the app targets macOS.
    #[cfg(target_os = "macos")]
    {
        build_native_permissions_bridge();
        build_stt_sidecar();
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
    println!("cargo:rustc-link-lib=framework=AVFoundation");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=Speech");
}

#[cfg(target_os = "macos")]
fn build_stt_sidecar() {
    use std::path::PathBuf;
    use std::process::Command;

    let manifest = env!("CARGO_MANIFEST_DIR");
    // Rust target triple (e.g. aarch64-apple-darwin) — matches the suffix Tauri
    // appends to `binaries/stt-ondevice`.
    let target = std::env::var("TARGET").expect("TARGET set by cargo");
    let src = format!("{manifest}/sidecars/stt-ondevice/main.swift");
    let plist = format!("{manifest}/sidecars/stt-ondevice/Info.plist");
    let entitlements = format!("{manifest}/sidecars/stt-ondevice/entitlements.plist");
    let out_dir = PathBuf::from(manifest).join("binaries");
    std::fs::create_dir_all(&out_dir).expect("create binaries dir");
    let out = out_dir.join(format!("stt-ondevice-{target}"));

    println!("cargo:rerun-if-changed={src}");
    println!("cargo:rerun-if-changed={plist}");
    println!("cargo:rerun-if-changed={entitlements}");

    // Builds for the host arch (correct for native dev/release builds); universal
    // / cross-arch packaging is an area:release concern (#54).
    let status = Command::new("swiftc")
        .args(["-O", "-o"])
        .arg(&out)
        .arg(&src)
        .args([
            "-Xlinker",
            "-sectcreate",
            "-Xlinker",
            "__TEXT",
            "-Xlinker",
            "__info_plist",
        ])
        .arg("-Xlinker")
        .arg(&plist)
        .status()
        .expect("run swiftc for the stt-ondevice sidecar");
    assert!(
        status.success(),
        "swiftc failed for the stt-ondevice sidecar"
    );

    // Bind the embedded Info.plist to the code signature so crash reports and code
    // identity stay readable. The app bundle owns first-run permission prompts.
    let signed = Command::new("codesign")
        .args([
            "--force",
            "--sign",
            "-",
            "--identifier",
            "com.handsoff.desktop.stt",
            "--entitlements",
            &entitlements,
        ])
        .arg(&out)
        .status()
        .expect("run codesign for the stt-ondevice sidecar");
    assert!(
        signed.success(),
        "codesign failed for the stt-ondevice sidecar"
    );
}
