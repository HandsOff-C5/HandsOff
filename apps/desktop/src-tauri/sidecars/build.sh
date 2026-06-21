#!/usr/bin/env bash
# Compiles the on-device STT Swift sidecar (#31, AD2) into the location Tauri's
# `externalBin` resolver expects: `binaries/stt-ondevice-<target-triple>`.
#
# No network, no API key — the sidecar runs Apple's on-device speech recognition.
# Run from anywhere; paths are resolved relative to this script.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/stt-ondevice/main.swift"
triple="${1:-$(rustc -vV | sed -n 's/host: //p')}"
out_dir="$here/../binaries"
out="$out_dir/stt-ondevice-$triple"

mkdir -p "$out_dir"
echo "Building on-device STT sidecar for $triple"
swiftc -O -o "$out" "$src"
echo "ok → $out"
file "$out"
