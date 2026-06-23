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
  local src_dir="$here/head-track"
  local plist="$here/head-track/Info.plist"
  local entitlements="$here/head-track/entitlements.plist"
  local out_dir="$here/../binaries"
  local out="$out_dir/head-track-$triple"

  mkdir -p "$out_dir"
  echo "Building head-track sidecar for $triple"
  swiftc -O -o "$out" "$src_dir"/*.swift \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework QuartzCore \
    -framework Vision \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist"
  codesign --force --sign - --identifier com.handsoff.desktop.headtrack --entitlements "$entitlements" "$out"
  "$out" --selftest
  echo "ok → $out"
  file "$out"
}

if [[ "${1:-head-track}" == "head-track" ]]; then
  build_head_track "${2:-$(host_triple)}"
  exit 0
fi

echo "usage: $0 [head-track] [target-triple]" >&2
exit 64
