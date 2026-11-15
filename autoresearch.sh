#!/usr/bin/env bash
# Autoresearch harness for kmshaunt <-> ghostty rendering parity.
#
# ALL builds and VMs run on tensor (10.4.1.100) over a persistent SSH
# ControlMaster. The laptop only syncs source, fetches the screenshots and
# aggregates the metric; it never boots a VM.
#
# Boots two identical NixOS VMs on tensor (kmshaunt on the DRM console; ghostty
# fullscreen under cage), cats every fixtures/ghostty-parity frame into each,
# QMP-captures the framebuffer, and emits the aggregate pixel diff. Lower is
# better; 0 means byte-exact across all frames.
#
#   Primary metric:   total_abs_diff  sum of per-pixel |dR|+|dG|+|dB| over frames
#   Secondary metric: pixel_diff      count of pixels with any channel difference
#
# run_experiment executes this as `bash autoresearch.sh`. Each iteration rebuilds
# kmshaunt from current src and boots both VMs, so pass a generous
# timeout_seconds (e.g. 3000) when calling run_experiment.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CP=${TENSOR_CP:-/home/nil/.ssh/control/tensor}
HOST=${TENSOR_HOST:-root@10.4.1.100}
SSH="ssh -o ControlPath=$CP $HOST"
RDIR=/tmp/kmshaunt-parity
FONT_SRC=${COMIC_CODE_DIR:-$PWD/../nixos-config/modules/packages/comic-code}

# The capture builds flake.packages.kmshaunt, and a flake only sees git-tracked
# content: stage in-scope edits so the build measures the current worktree.
git add -A -- src nix/tests/ghostty-parity-capture.nix build.zig build.zig.zon deps.nix nix/package.nix

# 1. Sync source plus the shared comic-code font module (the capture wrapper
#    reads it from the sibling nixos-config checkout) to tensor. zig-pkg is
#    excluded: the nix build re-populates it from deps.nix.
rsync -a --delete \
  --exclude .zig-cache --exclude zig-pkg --exclude zig-out \
  --exclude result --exclude result-parity --exclude parity-inspect \
  -e "ssh -o ControlPath=$CP" ./ "$HOST:$RDIR/"
$SSH "mkdir -p /tmp/nixos-config/modules/packages"
rsync -a --delete -e "ssh -o ControlPath=$CP" \
  "$FONT_SRC/" "$HOST:/tmp/nixos-config/modules/packages/comic-code/"

# 2. Capture on tensor, detached so a dropped SSH channel cannot abort it. The
#    runner writes a .done marker holding the build/test exit code.
$SSH "cat > $RDIR-run.sh" <<RUN
#!/bin/sh
cd $RDIR
nix build --option sandbox false --impure --accept-flake-config \\
  -f nix/tests/ghostty-parity-capture-build.nix \\
  --out-link result-parity >$RDIR.log 2>&1
echo \$? > $RDIR.done
RUN
$SSH "chmod +x $RDIR-run.sh; rm -f $RDIR.done; nohup $RDIR-run.sh >/dev/null 2>&1 </dev/null & echo started"

# 3. Wait for the done marker (cold build ~20 min, warm ~6 min). Retry reads:
#    the control-master can transiently refuse a channel.
DONE=""
for _ in $(seq 1 480); do
  DONE=$($SSH "cat $RDIR.done 2>/dev/null" 2>/dev/null) && [ -n "$DONE" ] && break
  sleep 5
done
[ -n "$DONE" ] || { echo "autoresearch: tensor capture timed out" >&2; exit 1; }
if [ "$DONE" != "0" ]; then
  echo "autoresearch: capture build/test FAILED (last 40 lines):" >&2
  $SSH "tail -40 $RDIR.log" >&2 || true
  exit 1
fi

# 4. Fetch the screenshots (result-parity is a store symlink; resolve it first)
#    and aggregate locally. No VM runs on the laptop.
OUT=$($SSH "readlink -f $RDIR/result-parity")
mkdir -p result-parity
rsync -a --delete -e "ssh -o ControlPath=$CP" "$HOST:$OUT/" result-parity/

nix shell --impure --expr \
  '(import (builtins.getFlake (toString ./.)).inputs.nixpkgs { system = builtins.currentSystem; }).python3.withPackages (ps: [ ps.pillow ps.numpy ])' \
  --command python3 nix/tests/parity-metric.py result-parity
