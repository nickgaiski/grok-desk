#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
shader_tmp="$(mktemp -d /tmp/grok-shaders.XXXXXX)"
trap 'rm -rf "$shader_tmp"' EXIT
xcrun -sdk macosx metal -std=metal3.0 -mmacosx-version-min=14.0 -c "$root/Shaders/Glass.metal" -o "$shader_tmp/Glass.air"
xcrun -sdk macosx metallib "$shader_tmp/Glass.air" -o "$root/Sources/GrokDesk/Resources/default.metallib"
