#!/usr/bin/env bash
# Compiles the on-device STT Swift sidecar (#31, AD2) into the location Tauri's
# `externalBin` resolver expects: `binaries/stt-ondevice-<target-triple>`.
#
# No network, no API key — the sidecar runs Apple's on-device speech recognition.
# Run from anywhere; paths are resolved relative to this script.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/stt-ondevice/main.swift"
plist="$here/stt-ondevice/Info.plist"
triple="${1:-$(rustc -vV | sed -n 's/host: //p')}"
out_dir="$here/../binaries"
out="$out_dir/stt-ondevice-$triple"

mkdir -p "$out_dir"
echo "Building on-device STT sidecar for $triple"
# Embed the Info.plist into __TEXT,__info_plist for readable helper identity.
# macOS TCC still rejects raw sidecar permission prompts, so the helper reports
# missing grants instead of requesting them directly.
swiftc -O -o "$out" "$src" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist"
# Bind the embedded Info.plist to the code signature. A signed app bundle that
# embeds this sidecar re-signs it with the app identity at package time.
codesign --force --sign - --identifier com.handsoff.desktop.stt "$out"
echo "ok → $out"
file "$out"
