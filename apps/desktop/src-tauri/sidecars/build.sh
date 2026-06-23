#!/usr/bin/env bash
# Compiles Swift sidecars into the location Tauri's `externalBin` resolver
# expects: `binaries/<sidecar>-<target-triple>`.
# Run from anywhere; paths are resolved relative to this script.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

host_triple() {
  rustc -vV | sed -n 's/host: //p'
}

build_head_track() {
  local triple="$1"
  local src="$here/head-track/main.swift"
  local plist="$here/head-track/Info.plist"
  local entitlements="$here/head-track/entitlements.plist"
  local out_dir="$here/../binaries"
  local out="$out_dir/head-track-$triple"

  mkdir -p "$out_dir"
  echo "Building head-track sidecar for $triple"
  swiftc -O -o "$out" "$src" \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework QuartzCore \
    -framework Vision \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist"
  codesign --force --sign - --identifier com.handsoff.desktop.headtrack --entitlements "$entitlements" "$out"
  echo "ok → $out"
  file "$out"
}

if [[ "${1:-}" == "head-track" ]]; then
  build_head_track "${2:-$(host_triple)}"
  exit 0
fi

src="$here/stt-ondevice/main.swift"
plist="$here/stt-ondevice/Info.plist"
entitlements="$here/stt-ondevice/entitlements.plist"
triple="${1:-$(host_triple)}"
out_dir="$here/../binaries"
out="$out_dir/stt-ondevice-$triple"

mkdir -p "$out_dir"
echo "Building on-device STT sidecar for $triple"
# Embed the Info.plist into __TEXT,__info_plist for readable helper identity.
# The app bundle owns first-run permission prompts.
swiftc -O -o "$out" "$src" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist"
# Bind the embedded Info.plist to the code signature. A signed app bundle that
# embeds this sidecar re-signs it with the app identity at package time.
codesign --force --sign - --identifier com.handsoff.desktop.stt --entitlements "$entitlements" "$out"
echo "ok → $out"
file "$out"
