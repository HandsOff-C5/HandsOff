// Product branding shared across every area. This lives in `contracts` because
// it is the only package every other area may import, so the name is defined
// once here and a rebrand is a single-line change rather than a hunt through
// runtime strings. Comments and build config (tauri.conf.json, index.html) refer
// to the product by name in prose and cannot consume this constant.
export const APP_NAME = "HandsOff";
