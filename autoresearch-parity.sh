#!/usr/bin/env bash
# Autoresearch harness for kmshaunt <-> ghostty rendering parity.
#
# Boots two identical NixOS VMs (kmshaunt on the DRM console; ghostty fullscreen
# under cage), cats every fixtures/ghostty-parity frame into each, QMP-captures
# the framebuffer, and emits the aggregate pixel diff. Lower is better; 0 means
# byte-exact across all frames.
#
#   Primary metric:   total_abs_diff  sum of per-pixel |dR|+|dG|+|dB| over frames
#   Secondary metric: pixel_diff      count of pixels with any channel difference
#
# run_experiment executes this as `bash autoresearch-parity.sh`. Each iteration rebuilds
# kmshaunt from current src and boots both VMs, so pass a generous
# timeout_seconds (e.g. 1200) when calling run_experiment.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

build_log=$(mktemp)
trap 'rm -f "$build_log"' EXIT

# 1. Capture: rebuild kmshaunt, boot both VMs, screenshot every frame.
if ! nix build --impure --accept-flake-config \
      -f nix/tests/ghostty-parity-capture-build.nix \
      --out-link result-parity >"$build_log" 2>&1; then
  echo "autoresearch: capture build/test FAILED (last 40 lines):" >&2
  tail -40 "$build_log" >&2
  exit 1
fi

# 2. Aggregate the pixel diff; METRIC lines go to stdout for run_experiment.
nix shell --impure --expr \
  '(import (builtins.getFlake (toString ./.)).inputs.nixpkgs { system = builtins.currentSystem; }).python3.withPackages (ps: [ ps.pillow ps.numpy ])' \
  --command python3 nix/tests/parity-metric.py result-parity
