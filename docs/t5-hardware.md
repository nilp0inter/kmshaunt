# T5 real-hardware checklist (ROADMAP M8.4)

Assessed 2026-11-14 on the development workstation (read-only; the machine
is in active use: Wayland session, seat0, user `nil`, active VT `tty1`,
kernel 6.12.115, single Intel GPU). Every workstation query below was
non-disruptive: sysfs reads and GET-only DRM ioctls on `/dev/dri/card1`.
kmshaunt was NOT run on the workstation's real device.

**Verdict (updated 2026-11-14, tensor run): the M8 exit criterion "checklist
done on at least two GPU vendors" is now COVERED for the achievable items —
i915 (workstation, read-only) + amdgpu + nvidia-drm (tensor, kmshaunt
running on the real devices).** On tensor (`tensor.local`, NixOS, kernel
6.18.57, 2× AMD R9700 32 GB + 1× NVIDIA RTX A2000 12 GB) kmshaunt was built
and run on both vendors' DRM devices with the user's authorization; compute
workloads were stopped for the test window and restored afterwards. A real
4K@240 Hz panel was attached to the second R9700 mid-test, so amdgpu
additionally has real-panel evidence (backlight power-off confirmed by the
user, physical hotplug, visible rendering). nvidia-drm was tested headless
via a forced connector + EDID override. What remains open: Wayland-session
VT handoff (no graphical session exists on tensor), input-to-photon latency
(needs a measurement rig), and a real panel on the NVIDIA card. One
real-hardware usability finding (burst-pacing choppiness at 4K) is reported
below — report-only, no src change.

## Hardware inventory (read-only evidence)

| Fact | Value | Evidence |
|---|---|---|
| GPU | Intel `8086:7D55` (Meteor Lake-P, Intel Arc Graphics), PCI `0000:00:02.0`, subsystem `1043:1C43` | `/sys/bus/pci/devices/0000:00:02.0/{class,vendor,device}`; the only display-class (`0x030000`) PCI device on the machine |
| Driver | `i915` (not `xe`) | `/sys/class/drm/card1/device/uevent`: `DRIVER=i915` |
| DRM nodes | `card1` + `renderD128` | `/dev/dri`, `/sys/class/drm` |
| KMS resources | 4 CRTCs, 5 connectors, 13 encoders, 24 planes | `DRM_IOCTL_MODE_GETRESOURCES`, `GETPLANERESOURCES` (read-only, no master) |
| Active scanout | CRTC 82: 2880x1800@120Hz, fb 284 | `DRM_IOCTL_MODE_GETCRTC` (`mode_valid=1`); the Wayland compositor drives the panel at 120 Hz |
| Session | Wayland, seat0, active; active VT `tty1` | `loginctl show-session 1` (`Type=wayland`, `State=active`); `/sys/class/tty/tty0/active` |

Connectors (sysfs `status`/`enabled`/`dpms`/`modes` + read-only
`GETCONNECTOR`/`GETPROPERTY`):

| Connector | State | Enabled | DPMS | Modes | Physical size (kernel) |
|---|---|---|---|---|---|
| eDP-1 (id 241) | connected | enabled | On | 2880x1800@120Hz (preferred, 652264 kHz), 2880x1800@60Hz (652270 kHz) | 300x190 mm |
| eDP-2 (id 250) | connected | disabled | Off | identical to eDP-1 | 300x190 mm |
| DP-1 (id 258) | disconnected | — | Off | none | 0x0 |
| DP-2 (id 270) | disconnected | — | Off | none | 0x0 |
| HDMI-A-1 (id 279) | disconnected | — | Off | none | 0x0 |

Panel details:

- EDID basic block: 30x19 cm; the kernel reports the cm-rounded 300x190 mm.
  EDID detailed timing (DTD0): 2880x1800 px at **302x189 mm** — a ~14.0-inch
  16:10 panel, ~242 DPI diagonal. Both eDP connectors carry the identical
  EDID: eDP-2 is a second eDP link of the same built-in panel, not a second
  monitor [inference from identical EDID/modes; it is disabled and DPMS Off].
- eDP-1 properties: `vrr_capable=1`, `panel orientation=Normal`,
  `scaling mode=Full aspect`, `max bpc=8`, `link-status=Good`.
- DP-1/DP-2/HDMI-A-1 are physical ports available for a future hotplug test
  (all disconnected now).

## Checklist

Status legend: **verified-read-only** = checked on the real hardware without
running kmshaunt; **verified-real** = kmshaunt ran on the real device (tensor,
2026-11-14); **QEMU-emulated** = covered by the T3/T4 VM suite (state
transitions, not real-panel physics); **BLOCKED** = needs hardware/rig this
setup does not have. Per-vendor detail: "Tensor run" section below.

| T5 item | Status | Evidence / what was done | Still open |
|---|---|---|---|
| amdgpu driver | **verified-real** (tensor, 2× R9700) | kmshaunt drm2d + drm3d modeset and render on both cards; forced 1080p headless output and a real 3840x2160@240 Hz panel; fb captures, notcurses-demo visible on the panel | — |
| i915/xe driver | verified-read-only (presence); console run blocked on the workstation | `i915` bound and driving the eDP at 120 Hz; `xe` not bound on this kernel | Console run on a free VT; `xe` needs a kernel/config that binds `xe` |
| nouveau driver | BLOCKED | No nouveau-bound NVIDIA GPU on either machine (tensor's A2000 uses the proprietary driver) | A machine with NVIDIA + nouveau |
| nvidia-drm driver | **verified-real** (tensor, RTX A2000, headless forced output) | `nvidia_drm.modeset=1` (temporarily enabled, restored after); kmshaunt drm2d + drm3d modeset 1920x1080 on a forced DP-7 with EDID override; fb capture of the rendered console; DPMS Off/On; 4 cursor planes | Real panel on the NVIDIA card |
| HiDPI auto font size | **verified-real** (amdgpu) | `font-size=0` produced **15 px** on the forced 1920x1080/530x300 mm output and **23 px** on the real 3840x2160/700x390 mm panel — both exactly `height_px*254/(height_mm*60)`; workstation computation (40 px) below | nvidia-drm auto-size run (same formula; forced EDID mm available) |
| Monitor hotplug | **verified-real** (amdgpu) | Runtime hotplug ADD across GPUs (real panel attached while kmshaunt ran → opened + modeset silently); physical unplug/replug by the user → teardown + re-add; debugfs force/trigger on the headless card | Physical hotplug on nvidia-drm (no panel) |
| DPMS really powers the panel off | **verified-real** (amdgpu real panel; nvidia-drm property) | amdgpu: sysfs Off after `dpms-timeout`, **user confirmed the backlight went dark**, keypress woke it (Off→On). nvidia-drm: sysfs Off after idle, On after wake (no panel to observe) | Backlight observation on an NVIDIA panel |
| VT switch to/from a Wayland session | **verified-real** (VT/master handoff, amdgpu); Wayland handoff BLOCKED | `chvt 1` (agetty) ↔ `chvt 2` (kmshaunt) round-trip: master drop/retake, full redraw intact, input works after return. No Wayland session exists on tensor | Handoff to/from a live Wayland compositor |
| Hardware cursor plane | **verified-real** (amdgpu in situ; nvidia-drm presence + no-fallback) | amdgpu: CRTC CRC changes exactly when the pointer moves and returns when it moves back (cursor on a separate plane); 4 cursor planes/card. nvidia-drm: 4 cursor planes (256x256 caps), pointer moved with no software-cursor fallback and no cursor in the primary fb | Visual cursor confirmation on an NVIDIA panel |
| Input latency vs kmscon | BLOCKED (rig); kmscon parity run done on amdgpu | kmscon 10.1.1 modeset + rendered on the same R9700/panel; input-to-photon latency needs a photodiode/high-speed camera. Real-hardware finding: burst pacing makes animation input-paced at 4K (root-cause analysis below) | Latency rig; pacing policy review (report-only finding) |

## HiDPI auto font size — computation (not a console test)

Production path: `font-size=0` (the default; `kmshaunt.conf(5)`: "0 to derive
it from the display") → `setupFont` (`src/main.zig:1024`) → `autoFontSize`
(`src/main.zig:2387`):

```zig
if (mode.height_mm == 0) return 16;
const px = (@as(u64, mode.height_px) * 254) / (@as(u64, mode.height_mm) * 60);
return @intCast(std.math.clamp(px, 8, 72));
```

`height_mm` is the connector's `mm_height` from `drmModeGetConnector`
(`src/video/drm2d.zig`, `toVideoMode`), which reads **190** on this panel.

- `px = 1800 * 254 / (190 * 60) = 457200 / 11400 = 40` (u64 integer division;
  exact value 40.1) → **40 px**. The [8, 72] clamp is not reached.
- With the EDID DTD's 189 mm instead: `457200 / 11340 = 40` — same result,
  so the cm-rounding of the kernel's mm does not change the answer.
- Sanity: vertical DPI = `1800 / (190 / 25.4)` ≈ 240.6; 40 px ≈ a 12 pt font
  at panel DPI (`12/72 in × 240.6 ≈ 40.1`), matching the function's "~12 pt"
  intent. Diagonal DPI ≈ 242.9.
- Fallback: a connector reporting no physical size gets 16 px.
- Note: `src/font/atlas.zig` `computeAutoFontSize` is a different model
  (diagonal DPI × `default_pt` / 96) currently exercised only by unit tests;
  at 12 pt it would yield ≈ 30.4 px on this panel. The console uses
  `autoFontSize` above, not the atlas helper.

Real-panel confirmation (glyphs actually rasterized at 40 px, resulting grid
rows) requires running kmshaunt on the console — blocked while the user's
session is live.

## Hardware cursor planes — read-only enumeration

Method: open `/dev/dri/card1` `O_RDONLY`, set
`DRM_CLIENT_CAP_UNIVERSAL_PLANES` (cap 2, value 1) via
`DRM_IOCTL_SET_CLIENT_CAP` — a **per-file** capability that takes no master
and affects no other client — then `GETPLANERESOURCES`, `GETPLANE`,
`OBJ_GETPROPERTIES`, `GETPROPERTY` (all read-only). Without the cap the
kernel lists only the 16 overlay planes; primary and cursor planes are
hidden. kmshaunt's `detectCursorPlanes` needs the same cap
(`src/video/drm2d.zig:344`).

Result: **24 planes = 4 Primary + 16 Overlay + 4 Cursor.**

| Pipe (`possible_crtcs`) | Primary plane | Cursor plane | Cursor formats |
|---|---|---|---|
| A (0x1) | 32 | 77 | ARGB8888 only |
| B (0x2) | 84 | 129 | ARGB8888 only |
| C (0x4) | 136 | 181 | ARGB8888 only |
| D (0x8) | 188 | 233 | ARGB8888 only |

Cursor planes sit at `zpos=5`. kmshaunt matches the same immutable `type`
property (`PLANE_TYPE_CURSOR`, `src/video/drm2d.zig:1752`); per its
constraint #8, cursor caps alone do not prove a plane exists — the plane
list does. The hardware prerequisite for M5.7 is therefore satisfied on
i915. Whether kmshaunt's `SetCursor2`/async-update path works on this panel
can only be shown by running it (blocked here).

## QEMU coverage — what the emulated tests actually assert

Verified against the test sources (not just the ROADMAP wording):

- `nix/tests/m5-video.nix` (T4 parity, run against both kmscon and kmshaunt):
  variants `drm2d` / `drm3d` / `fbdev` (backend boot, autologin, `$TERM`,
  backend oracle), `rotate-0/90/180/270` (dual-OCR orientation oracle +
  grab-rotate cycle), `dpms` (`dpms-timeout=15`: sysfs `dpms` reads Off after
  idle, On after a keypress, text redrawn — bochs blanking only gates the
  DAC, so this proves state transitions, **not** panel power-off),
  `clone` / `scaled` (two explicit std VGA cards, both connectors enabled,
  per-output QMP screendumps + OCR).
- VT switch: `nix/tests/m1-login.nix` S2 (ctrl-alt-f2 away, ctrl-alt-f1 back,
  `/sys/class/tty/tty0/active` oracle, OCR-proven redraw) and
  `nix/tests/m8-perf.nix` (DRM master handoff between kmscon on tty2 and
  kmshaunt on tty1 in one VM).
- Runtime connector hotplug: **no VM scenario exists.** Covered at unit
  level with a fake udev event queue (`src/video/drm2d.zig` tests "hotplug:
  re-enumeration reflects disconnect, defers teardown mid-flip", "multi:
  hotplug tears down only the unplugged connector", "hotplug: monitor fd,
  drain events, idempotent enable, close on deinit"). Production is a libudev
  monitor on subsystem `drm`, filtered to `HOTPLUG=1` (M5.5).
- Cursor planes in QEMU: m5-video runs on std VGA (bochs), which has no
  cursor plane; cursor detection is covered by the fake-DRM unit tests, not
  by a VM scenario.

## Tensor — amdgpu + nvidia-drm real-hardware run (2026-11-14)

Host `tensor.local`: NixOS 26.11, kernel 6.18.57, 112 cores, headless compute
server (no graphical session; `agetty` on tty1 only). kmshaunt 0.0.1 built
on-host from the working tree (`nix build .#kmshaunt --option sandbox false`;
HEAD 8ff35bb, store `h16ymsys79bzycchy4xmlsniks1cb07l-kmshaunt-0.0.1`) and run
on tty2 with `--no-libseat --verbose --login -- /bin/sh`.

Safety: the user authorized stopping the compute workloads for the test
window. `llama-cpp.service` (CUDA on the A2000) and `radiance.service` (ROCm
on both R9700s) were `systemctl stop`ped before testing and `systemctl start`ed
afterwards (health re-verified via their listening ports 18080/8002).
`nvidia_drm.modeset` was N; it was temporarily enabled (`rmmod nvidia_drm &&
modprobe nvidia_drm modeset=1` — refcount 0, no process held card1 or
renderD128; CUDA uses /dev/nvidia0/nvidiactl/nvidia-uvm, untouched) and
restored to N afterwards. No DRM master was taken on any device driving an
active session; there was none.

### Hardware inventory (tensor)

| Card | GPU | PCI | Driver | VRAM | Connectors | Planes | Cursor caps |
|---|---|---|---|---|---|---|---|
| card0 | AMD R9700 (`1002:7551`, ASUS `1043:0626`) | 0000:d7:00.0 | amdgpu | 32 GB (34208743424 B) | DP-4/5/6, HDMI-A-2, Writeback-2 (all disconnected) | 4 Primary + 3 Overlay + 4 Cursor | 64x64 |
| card1 | NVIDIA RTX A2000 12 GB (`10de:2571`, Dell `1028:1611`) | 0000:17:00.0 | nvidia (open kernel module 595.104.02) | 12 GB | DP-7/8/9/10 (all disconnected) | 4 Primary + 4 Overlay + 4 Cursor | 256x256 |
| card2 | AMD R9700 (`1002:7551`) | 0000:75:00.0 | amdgpu | 32 GB | DP-1/2/3, HDMI-A-1, Writeback-1; **DP-3: real panel attached mid-test** | 4 Primary + 3 Overlay + 4 Cursor | 64x64 |

All cards: 4 CRTCs, dumb-buffer cap 1. Cursor planes: one per pipe
(`possible_crtcs` 0x1/0x2/0x4/0x8), amdgpu zpos 255. Evidence: sysfs
`device/uevent`, `mem_info_vram_total`, `/proc/driver/nvidia/gpus/*/information`,
read-only `GETRESOURCES`/`GETPLANERESOURCES`/`GETPLANE`/`OBJ_GETPROPERTIES`
with `DRM_CLIENT_CAP_UNIVERSAL_PLANES` (per-file, no master).

Real panel (card2-DP-3, attached by the user during the run): preferred
3840x2160@240 Hz (2332660 kHz), also 4K@60/144/95, 2560x1440, 1080p; EDID
384 bytes (2 blocks), physical size 70x39 cm → kernel mm 700x390. ~32-inch
4K class panel.

Pre-existing quirks (not caused by this run): `nvidia-smi` segfaults in
ld-linux since boot (dmesg at t+120 s, days before the test); compute health
was therefore checked via the services' ports, not nvidia-smi. amdgpu BAR
assignment warnings at boot (Resizable BAR); both GPUs compute normally.

### Method: headless forcing, real panel, capture, input

- **amdgpu headless forcing works via debugfs**: write a 128-byte EDID 1.3
  blob to `/sys/kernel/debug/dri/0/DP-4/edid_override`, `printf on > force`
  (no trailing newline — the write handler rejects it), `echo 1 >
  trigger_hotplug` → connector reads connected with the override's modes and
  mm. Reset: `printf unspecified > force`, truncate `edid_override`,
  re-trigger. Two synthetic EDIDs were used: 1920x1080@60 CEA timings at
  530x300 mm (→ auto font 15 px) and 3840x2160@60 at 300x190 mm (→ 48 px).
- **nvidia-drm headless forcing is different**: `trigger_hotplug` returns
  EACCES (nvidia-drm has no `output_poll_changed`); the core `force` flag is
  ignored by read-only detect (status stays disconnected); a raw legacy
  `SETCRTC` with a valid mode+fb on the still-disconnected connector fails
  EINVAL. **But a DRM-master client's forced connector probe latches the
  override**: after `force=on` + `edid_override` were set, kmshaunt's
  open/takeMaster re-probe made DP-7 connected (mm 530x300, 1920x1080 mode)
  and modeset it. The first kmshaunt open immediately after writing the
  override still saw disconnected; a later open succeeded. So nvidia-drm
  headless console use is possible with kmshaunt, but not via the
  debugfs-hotplug path that works on amdgpu.
- **Framebuffer capture** (no QMP on real hardware): `GETCRTC` → `GETFB2` →
  `PRIME_HANDLE_TO_FD` → `mmap` the dma-buf → PNG. Works for drm2d dumb
  buffers. drm3d (GBM) scanout buffers are tiled (amdgpu modifier
  0x200000000000305) and refuse CPU mmap (EPERM) — for drm3d, use CRTC CRCs
  or the user's eyes instead. nvidia-drm has no CRTC CRC debugfs; amdgpu does
  (`crtc-N/crc/{control,data}`, source `crtc`).
- **Input**: physical Logitech G610 USB keyboard (the user typed markers and
  ran notcurses-demo) plus uinput virtual keyboard/mouse for scripted tests.
  Kernel 6.18 uses a **16-byte `input_event`** (u32 sec/usec), not the old
  24-byte timeval layout — 24-byte writes are silently truncated to SYN-only
  events. libinput picks uinput devices up via udev hotplug (kmshaunt opened
  the new event nodes within a second).
- **Kernel UAPI layout notes** (6.18 vs older headers): `drm_mode_fb_cmd2`
  now has `flags` (u32) right after `pixel_format` and `modifier` as u64[4]
  at the end; `drm_mode_get_property` has `name` before the counts;
  `drm_mode_create_dumb` has `handle` before `pitch`. The ctypes probe used
  for this run had to match these.

### Per-vendor results

amdgpu (R9700, card0 forced headless + card2 real panel):

| Item | Result | Evidence |
|---|---|---|
| Driver load + KMS | pass | amdgpu bound; 4 CRTCs/11 planes per card; dumb buffers |
| Modeset | pass | forced 1920x1080@60 (card0) and real 3840x2160@240 (card2); sysfs enabled, `GETCRTC mode_valid=1`, debugfs state `allocated by = kmshaunt` |
| Console render | pass | fb captures: issue + shell prompt; user-visible on the real panel; notcurses-demo (Unicode planes, emoji, gradients, box drawing) rendered correctly |
| HiDPI auto font | pass | `console up: 192x60 grid, 15px font` (1080p/530x300 mm) and `256x77 grid, 23px font` (4K/700x390 mm); both = `height_px*254/(height_mm*60)` truncated |
| DPMS power-off | pass | `dpms-timeout=8`: sysfs Off after idle on both cards; **user confirmed the panel backlight went dark**; keypress → On; `--dpms-timeout=0` keeps it on |
| Hardware cursor | pass | 4 cursor planes; CRTC CRC (source `crtc`) stable when idle, changes on pointer move, returns to the exact prior CRC on move-back: 0x2e23/0x4b5c/0xb79c → 0xa1e2/0x4092/0xfa03 → 0x2e23/0x4b5c/0xb79c. Primary fb unchanged ⇒ cursor scans out on its own plane |
| Runtime hotplug | pass | real panel attached while kmshaunt ran → udev event → card2 opened + modeset (success path is silent); user unplugged/replugged DP → teardown (`hotplug open card2: NoConnectedDisplay` while unplugged) and re-add |
| VT switch | pass | `chvt 1` ↔ `chvt 2` round-trip: active VT follows, master drop/retake, session history intact in the post-switch capture, input works after return |
| drm3d (--hwaccel) | pass (init) | GBM/EGL/GLES2 came up on card1 AND card2 (`info: --hwaccel: drm3d on …`); scanout buffers tiled (no CPU capture); see pacing finding below |
| kmscon parity | pass (modeset+render) | kmscon 10.1.1 on the same card2/panel: `Preparing modeset for DP-3 at 3840x2160`, fb captured; `font_freetype: monospace: failed to match font` on this host (no fontconfig monospace match — environment, not a kmshaunt issue) |

nvidia-drm (RTX A2000, card1, headless forced DP-7):

| Item | Result | Evidence |
|---|---|---|
| Driver load + KMS | pass | `nvidia_drm modeset=1` reload; 4 CRTCs, 4 DP connectors, 12 planes, dumb buffers, cursor caps 256x256 |
| Modeset | pass | kmshaunt master probe latched force+EDID → DP-7 connected/enabled, CRTC 62 at 1920x1080@60, fb 150 |
| Console render | pass | fb capture of the rendered console (issue + prompt); notcurses-demo Unicode/emoji section captured on nvidia (demo reported 1.74K fps pty writes) |
| HiDPI auto font | pass (forced EDID) | `console up: 192x60 grid, 15px font` with the 530x300 mm override — same formula as amdgpu |
| DPMS | pass (property) | `dpms-timeout=8`: card1 sysfs Off after a 12 s idle window, On after uinput wake. No panel: backlight not observable |
| Hardware cursor | pass (no-fallback) | 4 cursor planes; pointer moved, no `cursorFallback` warning, no cursor image in the primary fb capture (legacy SetCursor2 succeeded ⇒ plane). Visual confirmation needs a panel |
| Runtime hotplug | blocked headless | `trigger_hotplug` EACCES; physical HPD needs a panel/dongle |
| drm3d (--hwaccel) | pass (init) | `info: --hwaccel: drm3d on /dev/dri/card1` |

### Real-hardware finding: animation was input-paced at 4K (fixed)

Symptom (user, real panel): notcurses-demo is "very choppy", but "every time
I press a key it displays a new frame"; typing fast yields "10x-20x more
frames". The same demo "worked beautifully" in the M8 QEMU VM.

Measurements on the real R9700 + 4K@240 panel (drm2d, demo bursting):

- Actual page-flip rate, polled via `GETCRTC` fb-id transitions: **3 flips in
  3.0 s (~1.1 fps, ~890 ms gaps)** in one demo section; ~2 fps (~500 ms gaps)
  in another. The demo itself reports 103–1740 fps — that is its pty write
  rate (consumption), not the display rate.
- Keypress → next flip: ~80 ms (dominated by the render itself, not by flip
  completion).
- Resolution comparison (same panel, `--mode=card2[DP-3]1920x1080@60`):
  ~2 fps (6 flips/3 s, ~500 ms gaps), auto font 11 px, grid 274x77. User:
  "faster, but not smooth … definitely faster." Only ~2x, not the ~4x the
  pixel count would suggest, because **auto font size keeps the cell count
  nearly constant** (4K 256x77 = 19712 cells vs 1080p 274x77 = 21098): the
  per-cell CPU render cost dominates and barely changes with resolution;
  only the back-buffer blit shrinks. So the choppiness is content/cell-cost
  driven and persists at every resolution — it is not a 4K-only or
  amdgpu-only artifact.
- The flip-completion path is healthy: the kernel only scans out a new fb
  when kmshaunt submits a flip, every submitted flip completes (front fb
  alternates cleanly), and `parseEvents`' cookie+crtc_id match works on
  amdgpu (FLIP_COMPLETE carries the real crtc id). This is NOT a lost-event
  stall: a stuck `flip_pending` would block `renderIfDirty` for input too.

Root cause — the M8.1 burst-coalescing policy, amplified by 4K frame cost:

- `renderIfDirty` → `deferBurstFrame` (src/main.zig): while a pty pump
  happened within the last refresh, the frame is deferred to
  `frame_due_ns = last_render_end + burstStretchNs(EWMA(frame_cost), refresh)`
  with `burstStretchNs = max(refresh, min(9 × cost, cap))`
  (`burst_stretch_factor = 9`; cap was `max_frame_stretch_ns = 1 s`, now
  `max_burst_frame_period_ns = 100 ms` — see the fix below).
- Instrumented `renderIfDirty` measured the demo's render+present cost at
  **~50 ms/frame** (49–66 ms) at 4K — CPU render of ~20000 cells of
  gradient/emoji content + the write-combining back-buffer blit into
  VRAM/GTT over PCIe. With the 1 s cap the stretch was ~9×50 = 450 ms →
  ~1–2 fps display.
- The input hook sets `frame_due_ns = 0` (src/main.zig, "a deferred arm would
  otherwise keep the echo waiting") → every keypress forces an immediate
  frame. Hence "frames only advance on keypress": the user is manually
  pumping the frame clock at typing speed while the background timer fires
  at the stretched rate.
- Why the VM looked fine: the M8 VM ran 1280x800 with a 50x160 grid (8000
  cells) on bochs with dumb buffers in guest RAM — cheap frames (~8 ms) →
  ~72 ms stretch → ~14 fps, and lighter benchmark content. The real panel
  runs ~20000 cells of notcurses-demo's gradient/emoji content into VRAM/GTT
  over PCIe write-combining. The policy bounds render *duty* (≤~10%) but not
  the frame *period*, so expensive content becomes a slideshow. libinput's
  "event processing lagging behind by 22–48 ms" warnings under burst input
  are the same render duty.

This is a pacing-policy usability regression for expensive content (many
cells / complex glyphs / large back-buffer blits), not a driver or flip-event
bug, and not specific to amdgpu or 4K — it just becomes visible there because
the real panel runs ~2.5x the VM's cell count with heavier content into
VRAM.

**Fix implemented (authorized):** cap the burst stretch at
`max_burst_frame_period_ns = 100 ms` (was 1 s) in `burstStretchNs`
(src/main.zig); unit tests extended. This caps the *deferral*, so a ~50 ms
frame presents every ~150 ms (~6.7 fps, up from ~1–2 fps); user verdict
"much better, still dropping some frames". A strict ≥10 fps floor for such
frames needs capping the *total* period (`stretch = min(9*cost, 100 ms -
cost)`) — further optimization deferred by request. **Throughput tradeoff
(measured, `just m8-perf`):** cell/scrolling benchmarks unchanged (1.33–1.80×
kmscon), but unicode regressed 72.3 → 32.2 MiB/s (1.20× → 0.52×, below
kmscon) — rasterization-bound frames force high render duty under any
display-rate floor. M8.1 equal-or-better no longer holds for unicode with
the floor; 9/10 benchmarks still ≥ kmscon. Full before/after table in
`docs/perf.md`.

### Session environment note (deployment, not a src bug)

The test launched `--login -- /bin/sh` directly, bypassing login/profile:
the session got kmshaunt's minimal env (PATH=/usr/local/bin:/usr/bin:/bin,
TERM=xterm-ghostty, no TERMINFO_DIRS). On NixOS that means almost no commands
resolve and curses apps fail with "terminfo error 0 for [xterm-ghostty]"
(notcurses: "EINVAL dimension required" until LINES/COLUMNS were exported).
The NixOS module (nix/module.nix) already handles this for real deployments:
it installs `ghostty.terminfo` into environment.systemPackages so
profileRelativeSessionVariables puts it on TERMINFO_DIRS, and a normal
`login -p` sources /etc/profile (NixOS PATH). The pty winsize is set
correctly (stty size = grid, e.g. 77x256). A bare-shell launch just needs
`. /etc/profile` (or the test's /tmp/t5-env).

### Still panel/rig-dependent after this run

- NVIDIA real panel: backlight power-off observation, visual cursor,
  physical hotplug (the A2000 has no display attached; forcing works for
  modeset/render/DPMS-property but not for HPD).
- VT handoff to/from a live Wayland session (tensor has no graphical
  session; the workstation's session must not be seized).
- Input-to-photon latency vs kmscon (photodiode/high-speed camera rig).
- nouveau and `xe` driver coverage (no such binding on either machine).


## What is blocked, and what unblocks it

1. **≥2-vendor exit (ROADMAP M8): COVERED for the achievable items.**
   amdgpu + nvidia-drm were run on tensor (above) alongside the workstation's
   read-only i915 assessment. Still uncovered: nouveau (no such binding on
   either machine) and `xe` (workstation kernel binds i915).
2. **Real-panel tests: done on amdgpu** (tensor's 4K@240 panel): DPMS
   backlight power-off (user-confirmed), physical hotplug, visible rendering,
   hardware cursor via CRTC CRC, VT/master round-trip, HiDPI auto font.
   The workstation's own Wayland session was never seized.
3. **Still open, and what unblocks each:**
   - **NVIDIA real panel:** attach a display (or an HPD-asserting EDID
     emulator) to the A2000 to observe backlight power-off, the visual
     cursor, and physical hotplug. Headless forcing already covers
     modeset/render/DPMS-property/cursor-plane presence.
   - **Wayland VT handoff:** needs a machine with a live Wayland session
     where console takeover is acceptable; run kmshaunt on a free VT,
     ctrl-alt-fN both ways, verify master drop/retake + redraw. tensor has
     no graphical session; the workstation's must not be disrupted.
   - **Input-to-photon latency vs kmscon:** a photodiode on the panel or a
     high-speed camera, both consoles under identical load. The M8.1 QEMU
     numbers are throughput, not latency. (kmscon parity modeset+render on
     the same R9700 is done.)
   - **Burst-pacing usability finding:** the input-paced animation above is
     a src policy change (report-only here); see the finding section.

## Reproducing the read-only checks

No root needed (user is in the `video` group); nothing here writes state:

- sysfs: `/sys/class/drm/` listing; `card1/device/uevent`;
  `card1-*/{status,enabled,modes,dpms,edid}`; `/sys/class/tty/tty0/active`;
  PCI scan of `/sys/bus/pci/devices/*/class` for `0x03*` (`lspci` is not
  installed on this machine).
- DRM ioctls on `/dev/dri/card1` opened `O_RDONLY`: `GETRESOURCES`,
  `GETCRTC`, `GETCONNECTOR`, `GETPROPERTY`, `GETPLANERESOURCES`, `GETPLANE`,
  `OBJ_GETPROPERTIES`, plus `SET_CLIENT_CAP(UNIVERSAL_PLANES)` (per-file).
  All GETs work without DRM master. `drm_info(1)` does the same in one shot
  if installed (it is not installed here); a ~200-line Python ctypes probe
  suffices otherwise.
- Auto font size: pure computation from the connector mm and the formula in
  `src/main.zig:autoFontSize` (above).

## Reproducing the tensor run

Root on tensor; stop compute first (`systemctl stop llama-cpp radiance`),
restore afterwards (`systemctl start …`, verify ports 18080/8002). Build:
rsync the tree (exclude `.git`/`.zig-cache`/`zig-pkg`/`zig-out`/`result*`) to
`/tmp/kmshaunt-t5`, `chown -R root:root`, `nix build .#kmshaunt --option
sandbox false --accept-flake-config`. Run on a free VT:
`kmshaunt --configdir=<empty> --vt=2 --no-libseat --verbose --dpms-timeout=0
--login -- /bin/sh` (set `XKB_CONFIG_ROOT` to a store xkeyboard-config).

- Headless amdgpu output: `cat edid.bin > /sys/kernel/debug/dri/0/DP-4/edid_override;
  printf on > …/force; echo 1 > …/trigger_hotplug` (reset with `printf
  unspecified > force`). nvidia-drm: same override+force, but no
  trigger_hotplug (EACCES) — kmshaunt's master probe latches it.
- Capture: `GETCRTC`→`GETFB2`→`PRIME_HANDLE_TO_FD`→mmap→PNG (drm2d dumb
  buffers only; drm3d GBM buffers are tiled, mmap EPERM). Flip rate: poll
  `GETCRTC` fb-id. Cursor: amdgpu `crtc-N/crc/{control,data}` (source `crtc`).
- Input: uinput (16-byte `input_event` on 6.18) or the physical keyboard.
- The ctypes probe, EDID generator, uinput keyboard/mouse and flip-rate
  scripts used here were throwaway (`/tmp/t5-tools` on both hosts at test
  time); framebuffer captures were saved under `/tmp/t5-evidence`.
