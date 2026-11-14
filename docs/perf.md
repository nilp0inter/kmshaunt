# kmshaunt performance (ROADMAP M8)

Measured and verified on 2026-11-13. Harness: `nix/tests/m8-perf.nix`
(run with `just m8-perf`); methodology and reproduction at the bottom.

Status of the M8 items:

| Item | Status |
|---|---|
| M8.1 vtebench throughput vs kmscon | 9/10 at or above kmscon (1.33–1.80x) via burst coalescing; unicode regressed to 0.52x as the deliberate cost of the 100ms display-rate floor added for real-hardware animation (T5 section below) |
| M8.2 damage-only presentation | drm2d + drm3d implemented (evidence below) |
| M8.3 memory @ 10k scrollback | measured: kmscon 57.7 MiB, kmshaunt 34.7 MiB peak RSS; sb-size byte-cap fixed (setScrollbackMaxBytes), re-measure pending |
| M8.4 T5 real hardware | ≥2-vendor exit COVERED for achievable items: amdgpu + nvidia-drm run on tensor (2026-11-14), i915 read-only on the workstation; real-panel DPMS/hotplug/cursor/HiDPI verified on amdgpu. Real-hardware finding: burst pacing made animation input-paced (1-2 fps) → display-rate floor added (see below) |
| M8.5 this document | written with the 2026-11-13 measured numbers |

## M8.1 — vtebench throughput: kmscon vs kmshaunt

Method (fixed, implemented in `nix/tests/m8-perf.nix`):

- ONE NixOS VM hosts both consoles: kmshaunt on tty1 (keeps the `autovt@`
  alias), kmscon on tty2 (its module's alias is cleared and the test starts
  `kmsconvt@tty2.service` explicitly). VT switching hands DRM master between
  them; only the active console renders. Same kernel, same QEMU process,
  same vCPUs for both — no cross-VM variance.
- Deterministic VM settings from `nix/tests/lib.nix` (`deterministicVm`):
  1024x768, pinned JetBrains Mono, blink off, `hardware.graphics.enable`.
  Both consoles: `font-name=JetBrains Mono`, `no-blink`, `sb-size=10000`,
  drm2d backend (std VGA / bochs-drm; `--hwaccel` currently falls back to
  drm2d, see M8.2). Only `$TERM` differs (`kmscon` vs `xterm-ghostty`).
- vtebench 0.3.1 from the pinned nixpkgs, full bundled suite (10
  benchmarks: cursor_motion, dense_cells, light_cells, scrolling,
  scrolling_bottom_region, scrolling_bottom_small_region,
  scrolling_fullscreen, scrolling_top_region, scrolling_top_small_region,
  unicode), default parameters: `--min-bytes 1048576 --max-secs 10
  --warmup 1`. vtebench writes each sample to the console pty and times how
  long the writes block, i.e. how fast the console consumes terminal output
  (vtebench `src/bench.rs` `run_sample`). stdout stays on the pty on
  purpose; redirecting it would measure nothing.
- Raw per-sample milliseconds are captured with `--dat`; throughput is
  derived as `sample_bytes / mean_ms`, where
  `sample_bytes = ceil(min_bytes / payload_len) * payload_len`
  (vtebench `Benchmark::new`). Sample sizes for this suite:
  cursor_motion 1,274,832 B; dense_cells 1,347,918 B; light_cells 1,049,958 B;
  scrolling / *_region / *_small_region 1,048,576 B; scrolling_fullscreen
  1,048,788 B; unicode 1,106,368 B.
- Order: kmscon first, then kmshaunt. vtebench's per-benchmark warmup plus
  the 10 s sampling window absorb cold-start effects; the order is recorded
  so a re-run can alternate it.
- vtebench truncates samples to whole milliseconds; a 0 ms mean yields only
  a lower bound on throughput (flagged `>=` in the summary and
  `mib_s_lower_bound` in perf.json).

Results (2026-11-13, tensor.local host, KVM, 1-vCPU 1 GiB VM, kernel
6.18.57, bochs-drm std VGA; tar-to-tensor + direct `nix build` because the
ssh-ng offload copies `.zig-cache` into the remote source and stalls):

kmscon, full suite, default parameters (grid 142x40, cell 9x20, auto
font size 20 px, drm2d, software cursor; suite wall time 149 s):

| benchmark | samples | mean ms | median ms | p90 ms | MiB/s |
|---|---|---|---|---|---|
| cursor_motion | 152 | 65.6 | 61 | 75 | 18.53 |
| dense_cells | 152 | 65.6 | 64 | 76 | 19.59 |
| light_cells | 220 | 44.9 | 43 | 47 | 22.29 |
| scrolling | 19 | 540.4 | 541 | 578 | 1.85 |
| scrolling_bottom_region | 32 | 313.8 | 314.5 | 326 | 3.19 |
| scrolling_bottom_small_region | 33 | 309.3 | 310 | 317 | 3.23 |
| scrolling_fullscreen | 146 | 68.1 | 66 | 79 | 14.69 |
| scrolling_top_region | 32 | 318.2 | 310.5 | 338 | 3.14 |
| scrolling_top_small_region | 32 | 315.4 | 318 | 323 | 3.17 |
| unicode | 72 | 138.3 | 125 | 213 | 7.63 |

kmshaunt: **the full vtebench suite did not complete within the 900 s
wait** (test aborted at the `test -s /tmp/kmshaunt.dat` timeout; no .dat
was written, so no per-benchmark numbers exist for this run). Quantitative
evidence of the gap from the same VM:

- `seq 1 20000` (108,894 bytes of short lines): kmscon consumed it in
  **1.06 s** (100.3 KiB/s), kmshaunt in **34.83 s** (3.1 KiB/s) —
  **32.9x slower** on line-by-line scrolling output.
- kmshaunt logged `libinput error: ... event processing lagging behind by
  73ms, your system is too slow` during the run.
- The harness dat wait has since been raised to 2400 s so a re-run can
  capture kmshaunt's full suite; the M8.1 target ("equal or better on
  every benchmark") is NOT met by the current build — closing the gap is
  follow-up work (likely the per-chunk render/flip pacing in the
  renderIfDirty loop, src/main.zig).

### Root cause and fix (2026-11-13, PerfFix)

The 33x gap was NOT render/flip pacing. Loop instrumentation (pump vs
render vs present timers) showed one `onPtyReadable` drain running
**40.7 s** straight through the whole `seq` burst while render averaged
129 us and present 8.8 ms: the bottleneck was `vt.write` (libghostty
parse) at ~3 KiB/s. The build summary gave the cause:
`compile lib ghostty-vt-static debug native` — kmshaunt's build.zig
called `b.lazyDependency("ghostty", .{})` with no options, and ghostty
reads its OWN `-Doptimize` (Config.zig `standardOptimizeOption`), so the
C library defaulted to **Debug** (runtime safety + `assertIntegrity` on
every PageList grow) while kmshaunt itself was ReleaseFast. kmscon's
optimized C parse is ~30x faster than a debug libghostty.

Fixes applied:

1. **build.zig**: propagate `.target`/`.optimize` into the ghostty
   dependency so libghostty-vt builds ReleaseFast (the decisive fix).
2. **Frame pacing (src/main.zig)**: `markDirty` no longer renders
   synchronously in the pty/input hot path. A one-shot frame timer (one
   display refresh, 4..50 ms clamp) coalesces damage into one render;
   flip completion (`onDrmEvent`) presents damage accumulated while a
   flip was in flight. Flips were already non-blocking submits.
3. **Bounded drain (src/session/terminal.zig)**: `onPtyReadable` drains
   at most 128 KiB per pump and returns "more pending"; the console
   re-arms the edge-triggered pty source (`epoll_ctl MOD` re-reports
   readiness), so a sustained burst can no longer monopolize the loop.
4. **Single-pass collection (src/render/cpu.zig)**: the redraw set is
   collected once per frame into a row-major snapshot; backgrounds and
   text both draw from it (the per-cell render-state C API was walked
   twice per frame before). Pixel-identical, halves the FFI cell cost.
5. **Band-limited present (src/main.zig)**: the trivial 1:1 path blits
   only the union of this frame's and the previous frame's damage bands
   (the back buffer is two frames stale under double buffering) instead
   of the whole canvas; the dumb-buffer mapping is write-combining, so a
   full-canvas memcpy costs milliseconds. full_redraw / unmergeable
   damage still copies everything.
6. **Shaped-cluster cache (src/render/cpu.zig)**: complex grapheme
   clusters (emoji ZWJ sequences, flags, combining marks) are shaped once
   and reused, keyed by (face, style, codepoints). Per-cluster HarfBuzz
   shaping dominated unicode frames (~290 ms/frame measured); the cache
   removes the repeat shaping.

The sb-size byte-cap gap (M8.3 below) was fixed in parallel
(terminal.zig `setScrollbackMaxBytes(sb_size * cols * 16)`).

### Results after the fix (same VM, same harness)

`seq 1 20000`: kmscon **1.06 s**, kmshaunt **1.06 s** — parity
(was 34.83 s, a **32.9x** speedup). The full vtebench suite now
completes (119.8 s; previously it did not finish within 900 s):

| benchmark | kmscon MiB/s | kmshaunt MiB/s | ratio |
|---|---|---|---|
| cursor_motion | 33.1 | 23.9 | 0.72 |
| dense_cells | 37.0 | 24.6 | 0.67 |
| light_cells | 72.5 | 34.0 | 0.47 |
| scrolling | 3.1 | 3.7 | 1.20 |
| scrolling_bottom_region | 4.6 | 5.1 | 1.10 |
| scrolling_bottom_small_region | 3.9 | 5.2 | 1.34 |
| scrolling_fullscreen | 23.8 | 18.3 | 0.77 |
| scrolling_top_region | 4.6 | 5.2 | 1.11 |
| scrolling_top_small_region | 5.0 | 5.1 | 1.02 |
| unicode | 61.3 | 4.6 | 0.08 |

Grid 50x160 on both consoles this run. All scrolling benchmarks are at
parity (0.94-1.11x across runs); the line-scrolling case that exposed
the 33x gap is at parity. The remaining gaps are render/present
efficiency, not loop blocking: the cell benchmarks are bounded by the
write-combining back-buffer blit (~7 ms/frame), and unicode by glyph
rasterization/compositing of color emoji. The shaped-cluster cache was
verified on a re-run: unicode moved only 4.6 -> 5.3 MiB/s, so the
synthetic unicode payload is rasterization-bound, not shaping-bound
(the cache still removes repeat shaping for real-world repeating
clusters). Closing the cell/unicode gaps fully needs a faster
back-buffer copy (non-temporal stores) and emoji raster caching —
follow-up render-efficiency work, separate from the M8.1 blocking fix.
Peak RSS after seq: kmscon 59,088 kB, kmshaunt 38,756 kB.

Raw data: test output `kmscon.dat` (221 lines of per-sample ms),
screenshots `m8-{kmscon,kmshaunt}-login.png`,
`m8-kmscon-vtebench-results.png`. The kmshaunt memory subtest and both
logins passed; VT switching between the two consoles in one VM works.

### Frame pacing: burst coalescing (2026-11-13, FramePacing)

The remaining cell/unicode gap after PerfFix was **render duty**, not
collection or parse speed. `renderIfDirty` (render + shadow→back-buffer
present) runs synchronously in the single-threaded epoll loop, so while a
burst renders every display refresh the pty pump only runs in the gaps:
`throughput = parse_rate × (1 − render_duty)`. Loop instrumentation (2 s
windows, `src/main.zig` probe) showed the cell benchmarks spending ~32% of
the loop in render+present (the write-combining back-buffer blit is
~7–8 ms/frame in the VM even with non-temporal stores) and unicode ~90%+
(glyph rasterization ~40–190 ms/frame), starving the pump. vtebench times
how long writes block, i.e. how fast the console *consumes* — so the
render path, not the parser, was the cap.

Fix (`src/main.zig`): **adaptive burst coalescing**. Each frame's
render+present cost is tracked (`burstCostEwma`); while pty output is
flooding in, the next frame is deferred to a deadline that stretches the
frame period (`burstStretchNs`, factor 9, cap 1 s) so render+present
occupies ≤ ~10% of the loop and the pty drains during the deferral.
Correctness/latency guards:

- Idle/interactive damage is never delayed: the burst gate requires a pty
  pump within the last refresh, and input clears the deadline and re-arms.
- A pending full redraw (VT switch, DPMS wake, zoom/rotate, hotplug)
  preempts a deferred arm (`frame_arm_deadline_ns`).
- Every frame is still a tear-free double-buffered page flip; when idle no
  timer is armed (no busy-loop). Cheap frames keep the refresh period.

Full harness re-run (`just m8-perf`, ONE VM, both consoles, default
`--min-bytes 1048576 --max-secs 10 --warmup 1`, mode 1280x800, grid 50x160,
sb-size=10000) — the authoritative same-VM comparison:

| benchmark | kmscon MiB/s | kmshaunt MiB/s | ratio |
|---|---|---|---|
| cursor_motion | 34.8 | 61.1 | 1.76 |
| dense_cells | 39.4 | 66.2 | 1.68 |
| light_cells | 76.9 | 108.2 | 1.41 |
| scrolling | 4.2 | 6.0 | 1.43 |
| scrolling_bottom_region | 5.2 | 7.1 | 1.37 |
| scrolling_bottom_small_region | 5.2 | 7.2 | 1.39 |
| scrolling_fullscreen | 33.1 | 54.1 | 1.64 |
| scrolling_top_region | 5.4 | 7.1 | 1.31 |
| scrolling_top_small_region | 5.2 | 7.2 | 1.40 |
| unicode | 60.3 | 72.3 | 1.20 |

**All 10 benchmarks meet or exceed kmscon (1.20–1.76×): the M8.1 target is
met** *(at this pre-floor revision; the 100 ms display-rate floor added later
for real-hardware animation regressed unicode to 0.52× — see the T5 section)*.
Before the fix (pre-fix tree, same-config pacing probe) the five gap
benchmarks were cursor_motion 24.2, dense_cells 22.6, light_cells 39.7,
scrolling_fullscreen 21.8, unicode 2.7 MiB/s. Pump duty rose from ~66% to
~90% (cells) and ~10% to ~85% (unicode); render frequency dropped ~10×.
Both logins, VT switching, and the memory subtest passed; kmshaunt peak RSS
after seq was 38,884 kB vs kmscon 59,200 kB.

Tradeoff: during a sustained burst the visible console updates at the
stretched frame rate (down to ~1/s for expensive unicode frames) rather
than every refresh — a throughput-vs-display-latency trade, **not** tearing
(flips stay vblank-synced). Interactive echo and full redraws are exempt;
idle rendering is unchanged.

## M8.3 — memory with 10,000 lines of scrollback

Method: on each console, `seq 1 20000` fills the scrollback
(`sb-size=10000` on BOTH consoles), then the console unit's MainPID
`/proc/<pid>/status` is read: `VmHWM` (peak RSS), `VmRSS`, `VmPeak`.
Measured before the vtebench run so benchmark glyph caches do not inflate
the number.

Results (same run as M8.1, after `seq 1 20000`, sb-size=10000 on both):

| console | VmHWM (peak RSS) | VmRSS | VmPeak |
|---|---|---|---|
| kmscon (tty2) | **59,136 kB (57.7 MiB)** | 59,136 kB | 77,392 kB |
| kmshaunt (tty1) | **35,516 kB (34.7 MiB)** | 35,516 kB | 57,580 kB |

kmshaunt's lower RSS is NOT a win: its scrollback is byte-capped (next
section), so it retains far fewer than the 10,000 lines kmscon retains.
The comparison is "kmshaunt byte-capped" vs "kmscon full 10k lines".

### GAP found: sb-size is capped by ghostty's default byte budget

kmshaunt applies `sb-size` as a LINE limit only:
`src/session/terminal.zig:269` calls `vt.setScrollbackMaxLines(cfg.sb_size)`
and nothing ever calls `setScrollbackMaxBytes` (grep of src/ confirms).

libghostty-vt 1.0.1 defaults `SCROLLBACK_MAX_BYTES` to **10,000 bytes**
(vendored source: `include/ghostty/vt/terminal.h:2339` "Back to the default
of 10,000 bytes"; `src/terminal/c/terminal.zig` tests expect 10_000). The
effective byte limit is `max(explicit, minMaxSize(cols, rows))`
(`src/terminal/PageList.zig:7826-7831`), and `minMaxSize` is two standard
pages for a viewport that fits one page (`PageList.zig:7907-7948`). History
pages are pruned as soon as `page_size` exceeds that byte limit
(`PageList.zig:4261-4262, 7842`), long before the 10,000-line limit is
reached.

Consequence: with sb-size=10000 the effective scrollback is roughly ONE
standard page of history rows (a few hundred rows at 1024x768), not 10,000
lines. kmscon's libtsm caps scrollback purely by lines
(`docs/reference/kmscon-options.md` §sb-size), so its sb-size=10000 retains
the full 10,000 lines. The M8.3 RSS comparison is therefore "kmshaunt with
sb-size=10000 configured (byte-capped)" against "kmscon with 10,000 lines
actually retained" — honest numbers, but the configured depth is not
honored. The binding to lift the cap already exists: `src/vt.zig:1356`
exposes `setScrollbackMaxBytes` (getter `scrollbackMaxBytes` at 1365;
exercised by the vt.zig test at 3417), but no session/main code calls it.
Follow-up fix: set a byte budget alongside the line budget in
`TerminalSession.init` (src/ change, outside the M8 measurement task).

## M8.2 — damage-only presentation (read-only code verification)

Verified against the tree at the time of the M8.1/M8.3 run (2026-11-13).

### drm2d: implemented (DirtyFB + dirty-row redraw)

- `src/video/drm2d.zig:965-1010` — `endFrame(damage)`:
  - converts the renderer's damage rects to half-open u16 clips, clipped to
    the mode of the fb being flipped, capped at `FB_DIRTY_MAX_CLIPS` (256)
    (lines 974-987);
  - sends them through `ops.dirty_fb` (line 989) before the flip;
  - submits `ops.page_flip` with `PAGE_FLIP_EVENT` (line 997).
- `src/video/drm2d.zig:1836-1839` — the real call is
  `drmModeDirtyFB(fd, fb_id, clips, n)`; `drmModePageFlip` at 1841-1843.
- `src/video/drm2d.zig:913-918` — DirtyFB support is probed once per modeset
  with empty clips; ENOSYS/EOPNOTSUPP permanently disables it (constraint
  #11, lines 74, 990-991). This is the common dumb-buffer case: bochs-drm
  (the VM's std VGA) does not implement DirtyFB, so in the benchmark VM the
  hint path is probed off and flips present without it.
- First frame after a modeset / DPMS-on presents without damage
  (`full_redraw`, constraint #10: lines 649-650, 972-974, 1096).
- The CPU renderer draws dirty rows only and appends one full-width damage
  band per redrawn row: `src/render/cpu.zig:352-411` (dirty check 352-357,
  redraw set 363-390, damage bands 402-411).
- The frame loop presents only when there is damage and no flip in flight,
  and passes the accumulated damage to `endFrame`:
  `src/main.zig:896-932` (`renderIfDirty`), `src/main.zig:939-980`
  (`present`; exact damage in the 1:1 case at 951-952, row-band physical
  damage for rotated/scaled viewports at 962-979). Line numbers are as of
  the 2026-11-13 measurement snapshot; main.zig is under concurrent edit,
  so locate by function name if they drift.

Caveats (legacy KMS semantics, not gaps against M8.2's wording):
- `drmModePageFlip` always scans out the whole framebuffer; the legacy API
  has no damage-restricted flip. Damage restriction is achieved by (a) the
  renderer redrawing only dirty rows and (b) the advisory DirtyFB hint,
  which is exactly what M8.2 asks for ("drmModeDirtyFB on drm2d"). The back
  buffer is kept complete by a full shadow-canvas blit each frame
  (`src/main.zig:950`), so correctness never depends on the hint.
- DirtyFB only saves panel-side work on drivers that implement it (e.g.
  PSR/manual-update panels); on bochs it is a no-op after the probe.

### drm3d: implemented (scissor + sub-upload + buffer-age replay)

- `src/video/drm3d.zig` `endFrame(damage)` now computes the effective present
  region and passes it to `presentStaging(rects)`: each rect is sub-uploaded
  via `glTexSubImage2D` (no full `glTexImage2D` per frame), then
  `glScissor` + scissored `glClear` + a quad sized to the rect. Empty damage
  = full frame (contract); also full on `full_redraw`, unknown buffer age,
  or rect overflow. Rects are clipped to the mode and merged like drm2d.
- GBM buffer recycling is handled via `EGL_BUFFER_AGE_EXT`: the backend
  replays the union of the last `age` frames' logical damage from a fixed
  8-frame ring (mesa `platform_drm.c` age semantics). Missing history/age →
  full frame. `beginFrame` no longer full-clears the recycled back buffer.
- Sub-width rects are row-copied into a tight scratch (GLES2 has no
  `UNPACK_ROW_LENGTH`); full-width rects upload in place.
- Verified: 21 drm3d tests (12 pre-existing + 9 new: empty=full, damage
  restricts upload/clear/draw, buffer-age replay, clip+merge, no-change zero
  work, full_redraw, GL-frame lazy clear, sub-width upload, age-query
  fallback). Tensor check phase green.
- `--hwaccel` now selects drm3d (GBM/EGL/GLESv2 wired in build.zig;
  `openDrmBackend` in main.zig). The GL-native renderer hooks still have no
  production caller; the backend conservatively forces full frames after
  GL-drawn frames until a GL renderer replays aged damage itself.

Conclusion: M8.2 is satisfied for BOTH backends — drm2d (DirtyFB + dirty-row
redraw) and drm3d (scissor + sub-upload + buffer-age replay).

## M8.4 — T5 real-hardware checklist: assessment

Workstation inventory (2026-11-13, via sysfs; lspci is not installed):

- One GPU only: Intel `8086:7D55` (Meteor Lake-P, Intel Arc Graphics),
  PCI 0000:00:02.0, driver `i915` (`/sys/bus/pci/devices/0000:00:02.0/uevent`).
- `/sys/class/drm`: card1 with eDP-1 (connected, enabled, 2880x1800),
  eDP-2 (connected, disabled), DP-1/DP-2/HDMI-A-1 (disconnected).
- `/dev/kvm` present; QEMU VMs run KVM-accelerated (the M8.1/M8.3 numbers
  are produced on tensor.local, 112 cores, also with /dev/kvm).

| T5 item | QEMU here | This workstation (real HW) | Status |
|---|---|---|---|
| amdgpu driver | no | no AMD GPU | HARDWARE-BLOCKED |
| i915/xe driver | bochs/virtio only | i915 present (MTL) | measurable on this machine (1 vendor) |
| nouveau driver | no | no NVIDIA GPU | HARDWARE-BLOCKED |
| nvidia-drm driver | no | no NVIDIA GPU | HARDWARE-BLOCKED |
| HiDPI auto font size | fixed 1024x768, fake EDID | 2880x1800 eDP panel | measurable on this machine; real-panel validation across vendors HARDWARE-BLOCKED |
| Monitor hotplug | virtio-gpu connector hotplug via QMP (M5) | physical unplug possible | QEMU covers the code path; real-connector behavior HARDWARE-BLOCKED for cross-vendor claim |
| DPMS panel power-off | sysfs/property state transitions only (bochs DPMS) | eDP DPMS possible | state transitions measurable in QEMU; actual panel power-off HARDWARE-BLOCKED |
| VT switch to/from Wayland | llvmpipe compositor possible | real session possible | partially measurable here; driver handoff across vendors HARDWARE-BLOCKED |
| Hardware cursor plane | bochs: none; virtio-gpu: cursor plane | i915 cursor plane | partially measurable in QEMU (virtio-gpu); real HW cursor behavior HARDWARE-BLOCKED for cross-vendor claim |
| Input latency vs kmscon | virtualization jitter dominates | needs measurement rig | HARDWARE-BLOCKED (meaningful numbers need real display + rig) |

ROADMAP M8 exit requires the checklist on at least two GPU vendors. This
workstation has exactly one (Intel/i915), so the M8.4 exit criterion is
HARDWARE-BLOCKED: amdgpu/nouveau/nvidia-drm coverage needs machines with
those GPUs. Everything QEMU can cover (throughput, memory, DPMS sysfs
states, VT switch, virtio-gpu hotplug/cursor) is covered by the T3/T4
suite and the M8 harness.

## M8.4 T5 — read-only real-hardware verification (2026-11-14)

Follow-up to the assessment above: the achievable non-disruptive checks were
run on the workstation while the user's Wayland session stayed active
(read-only sysfs + GET-only DRM ioctls on `/dev/dri/card1`; no DRM master,
no VT switch, no blanking, kmshaunt not run on the real device). Full
checklist, evidence and reproduction: `docs/t5-hardware.md`.

Verified read-only (Intel `8086:7D55` Meteor Lake-P, driver `i915`, kernel
6.12.115 — the only GPU on the machine):

- card1: 4 CRTCs, 5 connectors, 24 planes. eDP-1 connected/enabled,
  2880x1800@120Hz (CRTC 82 active), DPMS On; eDP-2 carries the identical
  EDID (second link of the same built-in panel), disabled, DPMS Off;
  DP-1/DP-2/HDMI-A-1 disconnected.
- Panel physical size: kernel 300x190 mm (EDID basic block 30x19 cm); EDID
  DTD 302x189 mm — ~14.0-inch, ~242 DPI diagonal.
- HiDPI `font-size=0` (auto): production formula `autoFontSize`
  (src/main.zig) = `height_px * 254 / (height_mm * 60)`, clamped [8, 72] →
  `1800*254/(190*60)` = **40 px** (same with the DTD's 189 mm; fallback
  16 px when mm is absent). Computation only — real-panel rendering needs
  a console run. (The atlas `computeAutoFontSize` diagonal-DPI helper is a
  unit-test-only variant, ≈30.4 px at 12 pt; not the production path.)
- Hardware cursor: with `DRM_CLIENT_CAP_UNIVERSAL_PLANES` (per-file cap, no
  master), 24 planes = 4 Primary + 16 Overlay + **4 Cursor** (one per pipe,
  ARGB8888-only, zpos 5). Without the cap only overlays are listed.
  kmshaunt's `detectCursorPlanes` uses the same enumeration; the M5.7
  hardware prerequisite is satisfied on i915.
- DPMS capability: connector `DPMS` property present (On on the active
  eDP-1). Actual panel power-off is not testable read-only.

QEMU coverage, verified against the test sources: `nix/tests/m5-video.nix`
(T4 parity, both nodes) covers drm2d/drm3d/fbdev boot, rotate-0/90/180/270,
`dpms` (sysfs Off after idle / On after keypress — bochs only gates the DAC,
so state transitions, not panel power) and clone/scaled two-card
multi-monitor at boot. VT switch: `m1-login.nix` S2 and `m8-perf.nix`
(master handoff between the two consoles). Runtime connector hotplug has
no VM scenario; it is covered by fake-udev-queue unit tests in
`src/video/drm2d.zig` (production: libudev `drm` monitor, HOTPLUG=1).

Still HARDWARE-BLOCKED: the ≥2-vendor M8 exit (only Intel here;
amdgpu/nouveau/nvidia-drm need other machines), and every real-panel test —
DPMS power-off, VT handoff to/from the live Wayland session, kmshaunt's
hardware cursor in situ, physical hotplug, input latency vs kmscon — all of
which require running kmshaunt on the console and would disrupt the active
session. The M8.1 numbers above are throughput, not input latency.

## Reproducing

    just m8-perf

Builds `nix/tests/m8-perf.nix` (one NixOS VM, both consoles) and runs it.
Results: `./result/perf-summary.txt`, `perf.json`, raw `kmscon.dat` /
`kmshaunt.dat`, screenshots, `env.txt`; the summary table also prints in
the build log.

Tensor offload (the recorded numbers were produced this way; the ssh-ng
client-side offload stalls because `builtins.getFlake` on the dirty tree
copies `.zig-cache` — 2.2 GB — into the remote source):

    # cache-free copy of the working tree (1.1 MB), then build ON tensor
    tar -cf - --exclude='./.git' --exclude='./.zig-cache' \
        --exclude='./.zig-global-cache' --exclude='./zig-pkg' \
        --exclude='./zig-out' --exclude='./result*' . \
      | ssh -o ControlPath=/home/nil/.ssh/control/tensor root@tensor.local \
          'rm -rf /tmp/kmshaunt-m8perf && mkdir -p /tmp/kmshaunt-m8perf \
           && tar -xf - -C /tmp/kmshaunt-m8perf'
    ssh -o ControlPath=/home/nil/.ssh/control/tensor root@tensor.local \
      'cd /tmp/kmshaunt-m8perf && nix build --option sandbox false \
         --accept-flake-config --impure --print-build-logs --expr "
        let
          flake = builtins.getFlake (toString ./.);
          system = builtins.currentSystem;
          pkgs = import flake.inputs.nixpkgs {
            inherit system;
            overlays = [ (import ./nix/overlay.nix) ];
          };
        in import ./nix/tests/m8-perf.nix {
          inherit pkgs;
          kmshauntModule = {
            imports = [ ./nix/module.nix ];
            services.kmshaunt.package =
              flake.packages.${system}.kmshaunt.overrideAttrs { doCheck = false; };
          };
        }"'

Notes:
- `doCheck=false` skips the package's `zig build test` gate only; the
  installed binary is built with the same flags (`-Doptimize=ReleaseFast
  -Dcpu=baseline`). Used because peers' in-flight src edits can transiently
  redden the unit tests (e.g. the font LCD test); the benchmark measures
  the binary, not the tests. Final union verification runs with the check
  phase enabled once the test fixes land.
- Checks wiring for `modules/flake/packages.nix` (owner: Main), same
  pattern as `kmshaunt-m1-login`:

      kmshaunt-m8-perf = pkgs.callPackage ../../nix/tests/m8-perf.nix {
        kmshauntModule = {
          imports = [ ../../nix/module.nix ];
          services.kmshaunt.package = config.packages.kmshaunt;
        };
      };

## M8.4 T5 — real-hardware run on tensor (2026-11-14)

kmshaunt was built and run on tensor's two GPU vendors (2× AMD R9700 32 GB
amdgpu + 1× NVIDIA RTX A2000 12 GB nvidia-drm, kernel 6.18.57), giving the
≥2-vendor coverage the workstation (Intel/i915 only) could not. Compute
workloads were stopped for the window and restored afterwards; nvidia-drm
KMS was temporarily enabled (`modeset=1`) and restored to `N`. Full checklist,
per-vendor evidence and reproduction: `docs/t5-hardware.md`.

Verified on real hardware (amdgpu, with a real 3840x2160@240 Hz panel on the
second R9700): modeset + rendering (fb captures + notcurses-demo visible on
the panel), HiDPI auto font (15 px @1080p/530x300 mm, 23 px @4K/700x390 mm,
11 px @1080p on the 4K panel — all exactly `height_px*254/(height_mm*60)`),
DPMS real backlight power-off (user-confirmed dark, keypress wake), physical
hotplug (unplug/replug teardown + re-add) and runtime cross-GPU hotplug add,
VT/master round-trip (chvt 1↔2), hardware cursor in situ (CRTC CRC changes on
pointer move, returns on move-back). nvidia-drm headless (forced DP-7 + EDID
override): modeset, rendering, DPMS Off/On, 4 cursor planes, drm3d init.
kmscon 10.1.1 modeset + rendered on the same R9700/panel (parity).

### Real-hardware finding: animation was input-paced (burst pacing)

notcurses-demo on the real 4K panel was "very choppy", but each keypress
produced a frame; fast typing gave "10x-20x more frames". The same demo was
smooth in the M8 QEMU VM. Measured display rate (GETCRTC fb-id transitions,
demo bursting, no input): **~1.1 fps (~890 ms gaps)** at 4K, ~2 fps (~500 ms)
in lighter sections and at 1080p. The demo's own 103–1740 fps is its pty
write rate (consumption), not the display rate. Keypress→flip ~80 ms
(render-dominated).

Root cause (NOT a driver/flip-event bug — the flip path is healthy: every
submitted flip completes, cookie+crtc match works on amdgpu): the M8.1 burst
coalescing `burstStretchNs = max(refresh, min(9*EWMA(frame_cost), 1 s))`
bounds render *duty* but not the frame *period*. Expensive content (~20k
cells of gradient/emoji + ~33 MB write-combining blit into VRAM/GTT) costs
~55–100 ms/frame → 0.5–0.9 s period → 1–2 fps. The input hook zeroes
`frame_due_ns`, so typing manually pumps the frame clock. Auto font size
keeps the cell count ~constant across resolutions (4K 256x77 vs 1080p
274x77), so the per-cell render cost — not the blit — dominates and the
choppiness persists at 1080p too. The VM looked fine because it ran 8000
cells of lighter content in guest RAM (~8 ms frames → ~14 fps).

### Fix: display-rate floor (src/main.zig)

Cap the burst *stretch* (deferral) at `max_burst_frame_period_ns = 100 ms`
(was 1 s): `burstStretchNs = max(refresh, min(9*cost, 100 ms))`. Cheap frames
(cost < ~11 ms, e.g. the cell benchmarks at ~8 ms → 72 ms) keep the pure
duty-bounding stretch unchanged; costlier frames defer at most 100 ms instead
of up to 1 s. Idle/interactive-exempt and full-redraw-preempt behavior
unchanged; `burstStretchNs` unit tests extended for the cap.

Note the total frame period is `render_cost + stretch`, so this caps the
*deferral*, not the absolute period: a ~50 ms frame still presents every
~150 ms (~6.7 fps). A strict ≥10 fps floor for such frames would require
capping the total period (`stretch = min(9*cost, 100 ms - cost)`), which is
further optimization deferred by request — the shipped change is the
stretch cap.

### Fix verification (2026-11-14)

Real hardware (R9700 + 4K@240 panel, notcurses-demo): instrumented
`renderIfDirty` measured the per-frame render+present cost at **~50 ms**
(49–66 ms, EWMA ~50–60 ms) — not the hundreds of ms first suspected. With
the 1 s cap the deferral was ~9×50 = 450 ms → ~1–2 fps; with the 100 ms cap
the deferral is 100 ms → ~6.7 fps for those frames. User verdict: "much
better, but still dropping some frames" (the heaviest sections still render
slower than 10 fps). The flip-completion path was confirmed healthy
(GETCRTC fb-id polling: every submitted flip completes; keypress→flip ~80 ms,
render-dominated).

vtebench, same VM harness (`just m8-perf`, 1280x800, grid 50x160), kmshaunt
before (1 s cap) vs after (100 ms cap), MiB/s:

| benchmark | kmscon | before | after | after/kmscon |
|---|---|---|---|---|
| cursor_motion | 34.4 | 61.1 | 61.8 | 1.80 |
| dense_cells | 38.8 | 66.2 | 65.9 | 1.70 |
| light_cells | 76.9 | 108.2 | 107.8 | 1.40 |
| scrolling | 4.2 | 6.0 | 5.9 | 1.41 |
| scrolling_bottom_region | 5.2 | 7.1 | 7.1 | 1.38 |
| scrolling_bottom_small_region | 5.4 | 7.2 | 7.2 | 1.34 |
| scrolling_fullscreen | 31.4 | 54.1 | 50.0 | 1.59 |
| scrolling_top_region | 5.3 | 7.1 | 7.0 | 1.33 |
| scrolling_top_small_region | 4.9 | 7.2 | 7.2 | 1.46 |
| unicode | 62.0 | 72.3 | 32.2 | 0.52 |

**Tradeoff:** the cell and scrolling benchmarks are essentially unchanged
(still 1.33–1.80× kmscon). **unicode regressed 72.3 → 32.2 MiB/s (1.20× →
0.52×), now below kmscon.** This is fundamental, not a tuning miss: unicode
frames are rasterization-bound (~100–190 ms), so any display-rate floor
forces high render duty and starves the pty pump. Keeping unicode ≥ kmscon
requires ~10% duty ≈ ~1 fps display — exactly the animation problem being
fixed. M8.1 "equal-or-better on every benchmark" therefore no longer holds
for unicode with the floor enabled (9/10 still ≥ kmscon); the interactive
usability gain is the accepted trade. Peak RSS unchanged (kmshaunt 38.8 MiB
vs kmscon 57.8 MiB after `seq 1 20000`).