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
    println!("cargo:rustc-link-lib=framework=AVFoundation");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=Speech");
}
