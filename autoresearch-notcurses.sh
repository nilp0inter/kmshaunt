#!/usr/bin/env bash
# autoresearch-notcurses.sh — kmshaunt notcurses-demo FPS benchmark on tensor's Radeon.
#
# Builds the CURRENT kmshaunt source on tensor, runs the full notcurses-demo
# inside it at 3840x2160@240 (card2-DP-3, the connected panel), captures the
# demo's -J JSON summary, and emits METRIC lines:
#   METRIC geomean_fps=<v>   (primary: geometric mean FPS over all demos)
#   METRIC <demo>_fps=<v>    (secondary: per-demo FPS = frames / (ns/1e9))
#
# notcurses-demo is the patched 3.0.17 build (fixes the free(results)-before-
# summary_json use-after-free that corrupted the JSON). See /tmp/notcurses-fix
# on tensor for the patch + rebuild recipe.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CP=/home/nil/.ssh/control/tensor
SSH="ssh -o ControlPath=$CP root@tensor.local"
RDIR=/tmp/kmshaunt-ar
NC=/nix/store/mb2yv7cb9214cbqzihh8rr3a6ndp95fy-notcurses-3.0.17/bin/notcurses-demo
DATA=/nix/store/mb2yv7cb9214cbqzihh8rr3a6ndp95fy-notcurses-3.0.17/share/notcurses
TI=/nix/store/04rsxlwv1qim5sim1wwlpl2s2rd9dajz-ghostty-1.4.0-terminfo/share/terminfo
SPEC=ixetunchdmbkywjgarvlsfqzo   # full 25-demo suite
JREM=/tmp/nc-ar.json

# 1. Sync source to tensor. zig-pkg is excluded: the nix build re-populates it
#    from deps.nix. Build caches are excluded to keep the transfer small.
rsync -a --delete \
  --exclude .zig-cache --exclude zig-pkg --exclude zig-out --exclude result \
  -e "ssh -o ControlPath=$CP" ./ root@tensor.local:$RDIR/

# 2. Build kmshaunt on tensor. doCheck=false skips the unit-test gate for fast
#    iteration (the binary is identical; only the test gate is skipped).
$SSH "chown -R root:root $RDIR && cd $RDIR && nix build --option sandbox false --impure --expr '(builtins.getFlake (toString $RDIR)).packages.x86_64-linux.kmshaunt.overrideAttrs { doCheck = false; }' -o result"
K=$RDIR/result/bin/kmshaunt

# 3. Free DRM master: kill any prior benchmark console on the VT. The [2]
#    bracket avoids pkill matching this SSH shell's own cmdline (self-match).
$SSH "pkill -f 'kmshaunt.*--vt=[2]' 2>/dev/null || true; sleep 1"

# 4. Run the full notcurses-demo inside kmshaunt at 3840x2160@240, detached on
#    tensor so a dropped SSH channel cannot abort the benchmark. The runner
#    writes the JSON plus a .done marker holding the child exit code. -c gives a
#    constant PRNG seed so runs are comparable; TERMINFO = ghostty terminfo.
$SSH "cat > /tmp/nc-ar-run.sh" <<RUN
#!/bin/sh
rm -f $JREM $JREM.done
$K --vt=2 --no-libseat --dpms-timeout=0 --mode 3840x2160@240 --oneshot -l /bin/sh -- -c 'TERMINFO=$TI $NC -c -J $JREM -p $DATA $SPEC'
echo \$? > $JREM.done
RUN
$SSH "rm -f $JREM $JREM.done; chmod +x /tmp/nc-ar-run.sh; nohup /tmp/nc-ar-run.sh >/tmp/kmshaunt-ar-run.log 2>&1 </dev/null & echo started"

# 5. Wait for the done marker (full suite ~4 min), then read the JSON. Retry the
#    reads: the control-master can transiently refuse a channel. notcurses
#    summary_json emits a trailing comma when the last spec demo is skipped, so
#    strip trailing commas before parsing.
DONE=""
for _ in $(seq 1 150); do
  DONE=$($SSH "cat $JREM.done 2>/dev/null" 2>/dev/null) && [ -n "$DONE" ] && break
  sleep 3
done
[ -n "$DONE" ] || { echo "METRIC geomean_fps=0"; echo "ASI error=run_timeout" >&2; exit 1; }
JSON=""
for _ in 1 2 3 4 5; do
  JSON=$($SSH "cat $JREM" 2>/dev/null) && [ -n "$JSON" ] && break
  sleep 2
done
[ -n "$JSON" ] || { echo "METRIC geomean_fps=0"; echo "ASI error=json_read_failed" >&2; exit 1; }
JSON_DATA="$JSON" python3 - <<'PY'
import os, sys, json, math, re
raw = re.sub(r",\s*([}\]])", r"\1", os.environ["JSON_DATA"])
d = json.loads(raw)["notcurses-demo"]
fps = {}
for name, r in d["runs"].items():
    ns, frames = int(r["ns"]), int(r["frames"])
    if ns > 0 and frames > 0:
        fps[name] = frames / (ns / 1e9)
if not fps:
    print("METRIC geomean_fps=0")
    sys.exit(1)
geo = math.exp(sum(math.log(v) for v in fps.values()) / len(fps))
print(f"METRIC geomean_fps={geo:.3f}")
for name in sorted(fps):
    print(f"METRIC {name}_fps={fps[name]:.3f}")
print(f"ASI rows={d['rows']}")
print(f"ASI cols={d['cols']}")
print(f"ASI demos={len(fps)}")
PY