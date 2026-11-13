# T5 real-hardware checklist (ROADMAP M8.4)

Assessed 2026-11-14 on the development workstation. This is a **read-only
assessment**: the machine is in active use (Wayland session, seat0, user
`nil`, active VT `tty1`, kernel 6.12.115). Every query below was
non-disruptive: sysfs reads and GET-only DRM ioctls on `/dev/dri/card1`.
kmshaunt was NOT run on the real device; no DRM master was taken, no VT was
switched, no panel was blanked, the user's session was not touched.

**Verdict: the M8 exit criterion "checklist done on at least two GPU
vendors" is HARDWARE-BLOCKED.** This machine has exactly one GPU vendor
(Intel, driver `i915`). Every item that needs kmshaunt running on the
console (real-panel DPMS power-off, VT handoff to/from the live Wayland
session, hardware cursor in situ, input latency, physical hotplug) is
additionally blocked on this machine while the session is live: running
kmshaunt would take DRM master and disrupt the user. Cross-vendor coverage
needs machines this workstation does not have.

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
running kmshaunt; **QEMU-emulated** = covered by the T3/T4 VM suite (state
transitions, not real-panel physics); **HARDWARE-BLOCKED** = cannot be done
with this machine/session.

| T5 item | Status | Evidence / what was done | What a real-hardware run requires |
|---|---|---|---|
| amdgpu driver | HARDWARE-BLOCKED | No AMD GPU (full PCI scan) | A machine with an AMD GPU |
| i915/xe driver | verified-read-only (presence); console run blocked here | `i915` bound and driving the eDP at 120 Hz; `xe` not bound on this kernel | Run kmshaunt on a free VT (disruptive while the session is live); `xe` coverage needs a kernel/config that binds `xe` |
| nouveau driver | HARDWARE-BLOCKED | No NVIDIA GPU | A machine with NVIDIA + nouveau |
| nvidia-drm driver | HARDWARE-BLOCKED | No NVIDIA GPU | A machine with the NVIDIA proprietary driver |
| HiDPI auto font size | verified-read-only (computation); real-panel render blocked | Expected **40 px** for this panel (computation below) | Run kmshaunt with `font-size=0` on the panel and measure the rendered cells |
| Monitor hotplug | unit-tested + QEMU boot-time multi-monitor; runtime hotplug on real HW blocked | udev hotplug path with fake-queue unit tests (below); m5-video multi-monitor is boot-time, not runtime | Run kmshaunt, physically plug/unplug DP/HDMI, observe re-probe and layout |
| DPMS really powers the panel off | QEMU-emulated (state only); real power-off blocked | m5-video `dpms` variant asserts sysfs Off/On; DPMS property exists here and reads On on the active eDP-1 | Run kmshaunt with `dpms-timeout`, observe the backlight actually go dark and wake on input |
| VT switch to/from a Wayland session | QEMU-emulated; real handoff blocked | m1-login S2 (away/back + redraw), m8-perf (master handoff between two consoles) | Run kmshaunt on a free VT next to the live Wayland session; switch both ways, verify master drop/retake and redraw |
| Hardware cursor plane | verified-read-only (presence); in-situ use blocked | 4 cursor planes, one per pipe (enumeration below) | Run kmshaunt without `--soft-cursor`; verify cursor-plane updates on the panel |
| Input latency vs kmscon | HARDWARE-BLOCKED | No measurement rig here; QEMU jitter dominates (M8.1 numbers are throughput, not latency) | Real display + latency rig (photodiode or high-speed camera), both consoles under identical load |

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

## What is blocked, and what unblocks it

1. **≥2-vendor exit (ROADMAP M8):** needs machines with amdgpu, nouveau and
   nvidia-drm (and optionally a kernel binding `xe`). This workstation has
   only Intel/i915; no query can change that.
2. **Every real-panel test** needs kmshaunt running on the console: it takes
   DRM master and switches VTs, which would disrupt the user's active
   Wayland session on this machine. Not performed, by safety constraint.
   To run them, use a machine (or a logged-out session) where console
   takeover is acceptable, start `kmshaunt-vt@` on a free VT, then:
   - **DPMS:** `dpms-timeout=15`, watch the backlight go dark, wake with a
     keypress; repeat on each vendor's driver.
   - **VT switch:** ctrl-alt-fN into the Wayland session and back; verify
     master drop/retake, no corruption, full redraw.
   - **Cursor:** without `--soft-cursor`, move the pointer and check the
     cursor plane updates; compare with `--soft-cursor` forced.
   - **Hotplug:** plug/unplug a monitor on DP/HDMI while kmshaunt runs;
     verify re-probe, layout and teardown (this machine has three such
     ports, all currently disconnected).
   - **HiDPI:** `font-size=0` on the 2880x1800 panel; verify 40 px cells.
   - **Latency:** identical rig for kmscon and kmshaunt (input timestamp →
     photodiode on the panel, or high-speed camera). The M8.1 QEMU numbers
     are throughput and say nothing about real input-to-photon latency.

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
