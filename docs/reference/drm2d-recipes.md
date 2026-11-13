# libdrm 2.4.134 — drm2d call recipes

Exact, pinned recipes for the drm2d backend: the libdrm calls, struct fields,
ordering constraints and errno cases needed for ROADMAP M1.3 (first modeset on
drm2d), M5 (video parity: DPMS, cursor, hotplug, `gpus=`) and M8.2
(damage-only presentation). Everything below was read from the pinned headers,
the pinned libdrm source, kmscon 10.1.0 and Linux v6.12 (the kernel the recipes
must hold against). Nothing is inferred from man pages where source was
available.

The doc assumes the C API is reached through `b.addTranslateC` (ROADMAP D3), so
every recipe is written as C and then annotated for the Zig side.

---

## 0. Provenance and pins

| Item | Value | Where verified |
|---|---|---|
| libdrm version | **2.4.134** | `nix eval nixpkgs#libdrm.version` → `"2.4.134"` |
| libdrm dev output | `/nix/store/bvfayc21wafivfm336sis18p2f5dq1s1-libdrm-2.4.134-dev` | `nix build nixpkgs#libdrm.dev --print-out-paths --no-link` |
| Libraries | `-L…-libdrm-2.4.134/lib -ldrm` (soname `libdrm.so.2`) | `lib/pkgconfig/libdrm.pc` |
| Include flags | `-I${includedir} -I${includedir}/libdrm` | `libdrm.pc` `Cflags:` |
| libdrm source | `…-libdrm-2.4.134.tar.xz` (`nix build nixpkgs#libdrm.src`) | used for `xf86drm*.c` line numbers |
| kmscon | 10.1.0, `/nix/store/87j2xajxjphwhla24iw4n9jpiy33av63-source` | `nix build nixpkgs#kmscon.src --print-out-paths --no-link` |
| Kernel ABI references | Linux **v6.12** `drivers/gpu/drm/*` | git.kernel.org `plain/…?h=v6.12` |

**Header placement matters.** `xf86drm.h` and `xf86drmMode.h` live in
`$dev/include/`, but `xf86drm.h:40` does `#include <drm.h>` and
`xf86drmMode.h:41-43` include `<drm.h>`, `<drm_mode.h>`, `<drm_fourcc.h>`. All
four of those live in `$dev/include/libdrm/`. A translateC step therefore needs
**both** include directories, exactly as the `.pc` file says:

```zig
// build.zig (M1 integration)
drm_c.addIncludePath(.{ .cwd_relative = "/nix/store/…-libdrm-2.4.134-dev/include" });
drm_c.addIncludePath(.{ .cwd_relative = "/nix/store/…-libdrm-2.4.134-dev/include/libdrm" });
exe.root_module.linkSystemLibrary("drm", .{});
```

**Citation convention.** `xf86drmMode.h:296` is the installed header in
`$dev/include/`. `drm.h:1208`, `drm_mode.h:1260` are the installed headers in
`$dev/include/libdrm/`. `xf86drmMode.c:1837` is the libdrm source tarball.
`drivers/gpu/drm/drm_auth.c:240` is Linux v6.12. `src/video/drm_shared.c:1227`
is kmscon 10.1.0.

### 0.1 Return-value conventions (read this before writing the wrapper)

libdrm is not consistent, and the difference decides whether you read `errno`
or a negative errno from the return value.

| Family | Example | Failure convention |
|---|---|---|
| `xf86drm.c` (core) | `drmSetMaster`, `drmDropMaster`, `drmGetCap`, `drmSetClientCap` | returns `-1`, **`errno` set** (`drmIoctl`, `xf86drm.h:133`) |
| `xf86drmMode.c` (KMS) | `drmModeSetCrtc`, `drmModePageFlip`, `drmModeAddFB2`, `drmModeCreateDumbBuffer`, `drmModeSetPlane` | returns **negative errno** (`xf86drmMode.c:65-69`: `return ret < 0 ? -errno : ret;`) |
| `drmModeGet*` | `drmModeGetResources`, `drmModeGetConnector`, `drmModeGetPlaneResources`, `drmModeObjectGetProperties`, `drmModeGetProperty` | returns `NULL`, **`errno` set** |
| `drmIsMaster` | — | returns `1`/`0`, never an errno (`xf86drm.c:3266-3283`) |
| `drmHandleEvent` | — | `0` ok, `-1` on read error (`errno` may be `EAGAIN`) |

Zig shape for the KMS family (negative errno):

```zig
fn kmsError(rc: c_int) !void {
    if (rc >= 0) return;
    const e: u32 = @intCast(-rc);
    return switch (e) {
        @intFromEnum(std.posix.E.ACCES) => error.AccessDenied,
        @intFromEnum(std.posix.E.BUSY) => error.Busy,
        @intFromEnum(std.posix.E.NOENT) => error.NotFound,
        @intFromEnum(std.posix.E.NOSYS),
        @intFromEnum(std.posix.E.OPNOTSUPP) => error.Unsupported,
        else => error.DrmCallFailed,
    };
}
```

### 0.2 ABI facts verified on x86_64 against the pinned headers

Compiled with `zig cc -I…-dev/include -I…-dev/include/libdrm` (throwaway
program, not committed). These are the numbers a debugger, an strace-style
dump or a hexdump of the ioctl argument will show; they also prove the
translateC output is being read correctly.

| Type | Size | Fields / offsets |
|---|---|---|
| `struct drm_event` | 8 | `type` @0, `length` @4 |
| `struct drm_event_vblank` | 32 | base @0, `user_data` @8, `tv_sec` @16, `tv_usec` @20, `sequence` @24, `crtc_id` @28 |
| `struct drm_mode_create_dumb` | 32 | `height` @0, `width` @4, `bpp` @8, `flags` @12, `handle` @16, `pitch` @20, `size` @24 |
| `struct drm_mode_map_dumb` | 16 | `handle` @0, `pad` @4, `offset` @8 |
| `struct drm_mode_cursor2` | 36 | `flags`, `crtc_id`, `x`, `y`, `width`, `height`, `handle`, `hot_x`, `hot_y` (all 4 bytes) |
| `struct drm_mode_set_plane` | 48 | see §8.2 |
| `struct drm_mode_fb_cmd2` | 104 | see §4.3 |
| `struct drm_mode_modeinfo` | 68 | `name[32]` @36 |
| `struct drm_clip_rect` | 8 | `x1,y1,x2,y2` as `__u16` |
| `struct drm_mode_rect` | 16 | `x1,y1,x2,y2` as `__s32` |
| `DRM_FORMAT_XRGB8888` | `0x34325258` | fourcc `'XR24'` (`drm_fourcc.h:175`) |
| `DRM_FORMAT_ARGB8888` | `0x34324152` | fourcc `'AR24'` (`drm_fourcc.h:180`) |

ioctl request numbers (subject to the ioctl encoding, stable on x86_64):

| ioctl | value |
|---|---|
| `DRM_IOCTL_MODE_GETRESOURCES` | `0xc04064a0` |
| `DRM_IOCTL_MODE_SETCRTC` | `0xc06864a2` |
| `DRM_IOCTL_MODE_CURSOR` / `CURSOR2` | `0xc01c64a3` / `0xc02464bb` |
| `DRM_IOCTL_MODE_PAGE_FLIP` | `0xc01864b0` |
| `DRM_IOCTL_MODE_DIRTYFB` | `0xc01864b1` |
| `DRM_IOCTL_MODE_CREATE_DUMB` | `0xc02064b2` |
| `DRM_IOCTL_MODE_MAP_DUMB` | `0xc01064b3` |
| `DRM_IOCTL_MODE_SETPLANE` | `0xc03064b7` |
| `DRM_IOCTL_MODE_ADDFB2` | `0xc06864b8` |

---

## 1. Open, DRM master and the VT relation

### 1.1 Open the node

kmscon opens the node through the VT/seat backend, not raw:

```c
/* kmscon src/uterm/vt.c */
return open(device, O_RDWR | O_CLOEXEC | O_NONBLOCK);
```

Opening a **primary** node (`/dev/dri/cardN`) implicitly makes the first opener
the DRM master while nobody else is master ("implicitly through opening the
primary device node when no one else is the current master", `drivers/gpu/drm/drm_auth.c:42-46`).
Render nodes (`/dev/dri/renderDN`) can never be master (§10). The implicit
master exists *before* `drmSetMaster` is called, so a kmshaunt that opens
`cardN` while no compositor holds it is already allowed to modeset even if
`drmSetMaster` is skipped — do not rely on that; make the call explicit.

### 1.2 Master calls

```c
/* xf86drm.h:769-771 */
extern int drmSetMaster(int fd);
extern int drmDropMaster(int fd);
extern int drmIsMaster(int fd);
```

`drmSetMaster`/`drmDropMaster` are thin `drmIoctl` wrappers
(`xf86drm.c:3256-3264`), so they return `-1` with `errno` set.

**`drmSetMaster` errno (Linux v6.12, `drm_auth.c:246-287`):**

| errno | Condition |
|---|---|
| `EACCES` | `!CAP_SYS_ADMIN` **and** this file was never master in this process (`drm_master_check_perm`, `drm_auth.c:234-244`) — e.g. a render-capable fd handed over by a non-root session controller |
| `EBUSY` | Another fd is the current master (`if (dev->master) { ret = -EBUSY; }`, `drm_auth.c:260-263`). **This is the "someone else owns the screen" case, not `EACCES`** |
| `EINVAL` | No master object for the file, or the file is a lease lessee (`drm_auth.c:265-281`) |
| `0` | Already current master: idempotent early-out (`drm_auth.c:257-258`) |

**`drmDropMaster` errno (`drm_auth.c:297-330`):** `EACCES` as above; `EINVAL`
when the fd is not the current master, when `dev->master` is empty, or for a
lease lessee. Dropping is idempotent only in the sense that a second drop on a
fd that already dropped returns `EINVAL` — treat `EINVAL` on drop as success.

**`drmIsMaster` (`xf86drm.c:3266-3283`)** probes by calling `drmAuthMagic(fd,0)`:
`AUTHMAGIC` is `DRM_MASTER`-gated (`drm_ioctl.c:590`), so a non-master fd gets
`EACCES` and the helper returns `0`; a master fd gets `EINVAL` (magic 0 is
invalid) and the helper returns `1`. Use it for assertions and for deciding
whether to call `drmSetMaster`; do not use it as a permission test for
anything else.

### 1.3 VT relation: `KD_GRAPHICS` / `KD_TEXT` and the VT handshake

kmscon's real-VT backend, in order (`src/uterm/vt_real.c:258-347`):

1. `open("/dev/ttyN", O_RDWR | O_NOCTTY | O_CLOEXEC)` (`open_tty`, `:193-233`).
2. `ioctl(tty, VT_GETSTATE, &vts)` → save `vts.v_active` as the VT to return to.
3. `ioctl(tty, KDSETMODE, KD_GRAPHICS)` (`:286`) — the kernel console stops
   drawing text into the scanout buffer.
4. `ioctl(tty, VT_SETMODE, &mode)` with
   `mode.mode = VT_PROCESS; mode.acqsig = SIGUSR1; mode.relsig = SIGUSR2;`
   (`:293-304`).
5. `ioctl(tty, KDGKBMODE, &saved)` then `KDSKBMODE, K_RAW` then `KDSKBMODE, K_OFF`
   (`:302-316`) — input comes from evdev/libinput, not the VT.
6. On the release signal (`SIGUSR2`): drop DRM master, stop the video backend,
   then `ioctl(tty, VT_RELDISP, 1)` to allow the switch. `VT_RELDISP, 0`
   refuses it (`real_sig_leave`, `:139-197`).
7. On the acquire signal (`SIGUSR1`): `ioctl(tty, VT_RELDISP, VT_ACKACQ)`
   (`:134`) and re-take master + re-run hotplug/modeset.
8. On close or any error path: restore `KDSKBMODE`, then
   `VT_SETMODE` with `mode.mode = VT_AUTO`, then `KDSETMODE, KD_TEXT`
   (`real_close`, `:360-397`; error unwinding `:340-352`).

Ordering consequences that bite:

- **`KD_GRAPHICS` before the first modeset.** The VT console owns the CRTC
  until `KDSETMODE` succeeds; modesetting first leaves the console blitting
  text over the scanout.
- **Drop master before `VT_RELDISP`.** If the new VT's owner (compositor) has
  to call `drmSetMaster`, our still-held master makes that fail `EBUSY`
  (`drm_auth.c:260-263`). kmscon's `drm_video_sleep` drops master
  (`src/video/drm_shared.c:1572-1596`) as part of leaving the foreground.
- **Never `KD_TEXT` while another VT is active.** `KD_TEXT` is per-VT state;
  kmscon sets it only on its own VT during close/error, never on VT-away.
- **`VT_ACKACQ` is mandatory** under `VT_PROCESS`, otherwise the kernel blocks
  the switch.
- The kernel does **not** drop master on VT switch. Either the session
  controller (logind/seatd) or the client must; kmscon does it itself in
  `drm_video_sleep` (`src/video/drm_shared.c:1597`).

### 1.4 Master lifecycle used by kmscon (copy this state machine)

| Event | Action | Source |
|---|---|---|
| start / VT acquire | `drmSetMaster(fd)`; on error return and retry later via a 50 ms timer | `drm_video_wake_up` `drm_shared.c:1555-1570`, `drm_video_arm_vt_timer` `:1213-1224` |
| no connected displays left | `drmDropMaster(fd)` (nothing to scan out, let someone else drive) | `drm_video_hotplug` `:1535-1536` |
| VT release / sleep | `drmDropMaster(fd)` after waiting for pending flips and clearing cursor/overlay planes | `drm_video_sleep` `:1572-1596` |
| device unplugged / fd error | remove the fd from the loop, stop using it (events do not reliably signal death) | `io_event` `:1160-1187` |

The 50 ms retry exists because a VT switch that races a compositor's master
grab returns `EBUSY`, not `EACCES`; kmscon caps it at 20 attempts
(`MAX_VT_TIMEOUT_RETRIES`, `:51`, `:1189-1211`). Keep that shape.

### 1.5 Client capabilities: exact order

```c
/* xf86drm.h:611, 671 */
extern int drmGetCap(int fd, uint64_t capability, uint64_t *value);      /* -1/errno */
extern int drmSetClientCap(int fd, uint64_t capability, uint64_t value); /* -1/errno */
```

Set, in this order, **immediately after open and before any enumeration**
(kmscon: `drm_video_init`, `src/video/drm_shared.c:1248-1308`):

| Cap | Value | errno / effect | Citation |
|---|---|---|---|
| `DRM_CLIENT_CAP_UNIVERSAL_PLANES` (2) | 1 | Without it `GETPLANERESOURCES` reports **only overlay planes** — no primary, no cursor | `drm_plane.c:792-799` |
| `DRM_CLIENT_CAP_ATOMIC` (3) | 1 | `EOPNOTSUPP` on non-atomic drivers. Implies `universal_planes = 1` and `aspect_ratio_allowed = 1` | `drm_ioctl.c:338-355` |
| `DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT` (6) | 1 | Requires atomic first (`EINVAL` otherwise), `EOPNOTSUPP` on non-virtualized drivers. Without it, virtualized atomic drivers **hide** their cursor plane | `drm_ioctl.c:366-376`, `drm_plane.c:801-812` |

kmscon treats a failed `UNIVERSAL_PLANES`/`ATOMIC` as "use the legacy modeset
path" and a failed hotspot cap as "no hotspot support"
(`drm_shared.c:1270-1285`); both are normal outcomes, not errors.

> Note for drm2d M1.3: the legacy path deliberately skips atomic. Universal
> planes is still worth setting because it is what exposes a cursor plane
> (§8) and the `type` property used to find the primary plane.

---

## 2. Enumeration

### 2.1 Resources

```c
/* xf86drmMode.h:281 */
extern drmModeResPtr drmModeGetResources(int fd);
```

`NULL` + `errno` on failure. The helper itself does the two-pass dance with a
retry when counts grew between calls (`xf86drmMode.c:164-240`), so one call is
enough. `DRM_IOCTL_MODE_GETRESOURCES` needs **no master** (`drm_ioctl.c:608`).

```c
typedef struct _drmModeRes {          /* xf86drmMode.h:73-89 */
    int count_fbs;      uint32_t *fbs;
    int count_crtcs;    uint32_t *crtcs;
    int count_connectors; uint32_t *connectors;
    int count_encoders; uint32_t *encoders;
    uint32_t min_width, max_width, min_height, max_height;
} drmModeRes;
```

`max_width`/`max_height` bound any mode you may set. `crtcs[i]` IDs are the
values for `possible_crtcs` bit *i* — the bit index, not the ID, is what
encoder/plane masks use (see §2.3).

### 2.2 Connector

```c
/* xf86drmMode.h:376-377 */
extern drmModeConnectorPtr drmModeGetConnector(int fd, uint32_t connectorId);
/* xf86drmMode.h:387-388 — no probe */
extern drmModeConnectorPtr drmModeGetConnectorCurrent(int fd, uint32_t connector_id);
```

```c
typedef struct _drmModeConnector {    /* xf86drmMode.h:205-224 */
    uint32_t connector_id;
    uint32_t encoder_id;              /* currently bound encoder, 0 if none */
    uint32_t connector_type;          /* DRM_MODE_CONNECTOR_* */
    uint32_t connector_type_id;       /* per-type number, NOT an object id */
    drmModeConnection connection;     /* CONNECTED=1, DISCONNECTED=2, UNKNOWN=3 */
    uint32_t mmWidth, mmHeight;       /* sink size in mm — feeds HiDPI auto font size */
    drmModeSubPixel subpixel;
    int count_modes;   drmModeModeInfoPtr modes;
    int count_props;   uint32_t *props;  uint64_t *prop_values;
    int count_encoders; uint32_t *encoders;
} drmModeConnector;
```

Two-phase ioctl detail from the header (`drm_mode.h:426-457`). The generic shape
is "first call reports counts, second fills arrays". libdrm does it in
`_drmModeGetConnector` (`xf86drmMode.c:508-560`) with one deliberate twist:
`drmModeGetConnectorCurrent` (probe = 0) sets `count_modes = 1` with a stack
scratch mode so the kernel does **not** reprobe, while `drmModeGetConnector`
(probe = 1) leaves `count_modes = 0` on the first call to ask for a forced EDID
probe.

**Forced probe and master.** `drmModeGetConnector` passes `probe = 1`
(`xf86drmMode.c:613-616`), which leaves `count_modes = 0` for the first ioctl.
The kernel force-probes EDID only if the caller is master; otherwise it
**silently demotes to a read-only probe** (`drivers/gpu/drm/drm_connector.c:3186-3197`).
So:

- Enumerate connectors **after** `drmSetMaster`, or a connector that has never
  been probed will report `count_modes == 0` and kmscon skips it
  (`drm_shared.c:1487-1492`).
- To avoid a needless EDID read use `drmModeGetConnectorCurrent` (probe = 0).

`connection` values: `DRM_MODE_CONNECTED = 1`, `DRM_MODE_DISCONNECTED = 2`,
`DRM_MODE_UNKNOWNCONNECTION = 3` (`xf86drmMode.h:190-194`), with the documented
policy: enable CONNECTED first, fall back to UNKNOWN if none are connected
(`xf86drmMode.h:185-188`).

**Preferred mode:** pick the first mode with `mode->type & DRM_MODE_TYPE_PREFERRED`
(`drm_mode.h:52`), else `modes[0]`. kmscon's rule is exactly that
(`init_modes`, `src/video/drm_shared.c:1355-1360`).

**Physical size** comes from `mmWidth/mmHeight` (not from the mode). Divide by
`hdisplay/vdisplay` for DPI (`src/video.zig` `Mode.width_mm/height_mm`).

`subpixel` is offset by one in libdrm (`r->subpixel = conn.subpixel + 1`,
`xf86drmMode.c:580`) because kernel 0 means "unknown"; do not reuse the raw
ioctl value.

`drmModeGetConnectorTypeName(uint32_t)` (`xf86drmMode.h:504-505`) returns
`"HDMI-A"`, `"eDP"`, … or `NULL`; kmscon builds display names as
`"%s-%d"` from type name + `connector_type_id` (`drm_shared.c:1402-1403`).
The sysfs name uses the same spelling with a dash: `/sys/class/drm/card0-HDMI-A-1`.

### 2.3 Encoder and CRTC selection

```c
/* xf86drmMode.h:365 */
drmModeEncoderPtr drmModeGetEncoder(int fd, uint32_t encoder_id);

typedef struct _drmModeEncoder {     /* xf86drmMode.h:170-176 */
    uint32_t encoder_id;
    uint32_t encoder_type;
    uint32_t crtc_id;                /* currently bound CRTC, 0 if none */
    uint32_t possible_crtcs;         /* bitmask of CRTC *indices* */
    uint32_t possible_clones;
} drmModeEncoder;
```

kmscon's algorithm, in order (`modeset_find_crtc`, `drm_shared.c:172-228`):

1. If `conn->encoder_id != 0`, `drmModeGetEncoder` it; if `enc->crtc_id` is set
   and not already used by another display, take it without a full modeset.
2. Otherwise walk `conn->encoders[i]`, and for each walk the CRTC list: pick
   `res->crtcs[j]` where `enc->possible_crtcs & (1 << j)` and the CRTC is free.
3. Remember `j` as the display's **crtc index**; plane masks
   (`plane->possible_crtcs`) and `1 << crtc_index` use the same index.

`drmModeConnectorGetPossibleCrtcs(fd, conn)` (`xf86drmMode.h:400-401`) returns
that mask directly and is the shorter path if you do not need the encoder.

### 2.4 Current CRTC: original mode and current scanout

```c
/* xf86drmMode.h:338 */
extern drmModeCrtcPtr drmModeGetCrtc(int fd, uint32_t crtcId);

typedef struct _drmModeCrtc {        /* xf86drmMode.h:157-168 */
    uint32_t crtc_id;
    uint32_t buffer_id;              /* current fb, 0 = disconnected/off */
    uint32_t x, y;                   /* scanout position in the fb */
    uint32_t width, height;
    int mode_valid;
    drmModeModeInfo mode;
    int gamma_size;
} drmModeCrtc;
```

This is where `use-original-mode` comes from: kmscon looks up the CRTC via
`conn->encoder_id` and saves its mode when it matches a connector mode
byte-for-byte (`init_modes`, `drm_shared.c:1340-1390`). `buffer_id` tells you
whether someone left a fb bound (a compositor or the fbcon) — a bind you must
replace with `drmModeSetCrtc` before flipping.

### 2.5 Planes and object properties

```c
/* xf86drmMode.h:435, 437, 444, 448 */
extern drmModePlaneResPtr drmModeGetPlaneResources(int fd);
extern drmModePlanePtr drmModeGetPlane(int fd, uint32_t plane_id);
extern drmModeObjectPropertiesPtr drmModeObjectGetProperties(int fd, uint32_t object_id, uint32_t object_type);
extern int drmModeObjectSetProperty(int fd, uint32_t object_id, uint32_t object_type, uint32_t property_id, uint64_t value);
/* xf86drmMode.h:414, 421 */
extern drmModePropertyPtr drmModeGetProperty(int fd, uint32_t propertyId);
extern int drmModeConnectorSetProperty(int fd, uint32_t connector_id, uint32_t property_id, uint64_t value);
```

```c
typedef struct _drmModeObjectProperties { uint32_t count_props; uint32_t *props; uint64_t *prop_values; }; /* :229-233 */
typedef struct _drmModePlaneRes { uint32_t count_planes; uint32_t *planes; };                              /* :256-259 */
typedef struct _drmModePlane {                                                                             /* :241-254 */
    uint32_t count_formats; uint32_t *formats; uint32_t plane_id;
    uint32_t crtc_id; uint32_t fb_id;
    uint32_t crtc_x, crtc_y, x, y;
    uint32_t possible_crtcs; uint32_t gamma_size;
};
typedef struct _drmModeProperty {                                                                          /* :134-144 */
    uint32_t prop_id; uint32_t flags; char name[DRM_PROP_NAME_LEN /*32*/];
    int count_values; uint64_t *values;
    int count_enums;  struct drm_mode_property_enum *enums;
    int count_blobs;  uint32_t *blob_ids;
};
```

Object type tokens for `DRM_MODE_OBJECT_*` (`drm_mode.h:624-633`):
`CRTC 0xcccccccc`, `CONNECTOR 0xc0c0c0c0`, `PLANE 0xeeeeeeee`,
`FB 0xfbfbfbfb`. Property flags (`drm_mode.h:518-545`): `ENUM (1<<3)`,
`BLOB (1<<4)`, `IMMUTABLE (1<<2)`, `ATOMIC 0x80000000`.

Reading a property value (no blob, no enums) costs one `drmModeObjectGetProperties`
call and one `drmModeGetProperty` per prop; kmscon caches `props_info[]` once
per object (`modeset_get_object_properties`, `drm_shared.c:110-124`). **Free
both** (`drmModeFreeObjectProperties`, `drmModeFreeProperty`) — these are
`malloc`-backed copies, one allocation per prop.

---

## 3. Legacy modeset

```c
/* xf86drmMode.h:343-345 */
int drmModeSetCrtc(int fd, uint32_t crtcId, uint32_t bufferId,
                   uint32_t x, uint32_t y, uint32_t *connectors, int count,
                   drmModeModeInfoPtr mode);
```

`drmModeSetCrtc` fills `struct drm_mode_crtc` (`drm_mode.h:277-290`): it copies
`*mode` into `crtc.mode` and sets `mode_valid = 1`; a `NULL` `mode` means
"disable this CRTC" and must be paired with `count == 0`
(`xf86drmMode.c:407-427`). `bufferId == 0` disables scanout.

`drmModeModeInfo` field semantics (`drm_mode.h:221-244`):

| Field | Unit / meaning |
|---|---|
| `clock` | pixel clock in **kHz** |
| `hdisplay`, `hsync_start`, `hsync_end`, `htotal` | pixels |
| `vdisplay`, `vsync_start`, `vsync_end`, `vtotal` | lines |
| `hskew`, `vscan` | legacy, 0 for modern modes |
| `vrefresh` | **approximate** vertical refresh in **Hz** (kernel-computed; may be 0 for user modes) |
| `flags` | `DRM_MODE_FLAG_*` (`PHSYNC 1<<0`, `NHSYNC 1<<1`, `PVSYNC 1<<2`, `NVSYNC 1<<3`, `INTERLACE 1<<4`, `DBLSCAN 1<<5`, `CSYNC 1<<6`) |
| `type` | `DRM_MODE_TYPE_PREFERRED (1<<3)`, `DRIVER (1<<6)`, `USERDEF (1<<5)` |
| `name` | `char[32]`, `DRM_DISPLAY_MODE_LEN` (`drm_mode.h:46`) |

Copy the mode **verbatim** from `conn->modes[i]` (same struct layout; kmscon
`memcmp`s it to detect the original mode). The kernel rejects anything it
cannot validate: `drm_mode_convert_umode` failures, unsupported primary-plane
format, or a viewport that does not fit → `EINVAL`.

**Errno (`drm_mode_setcrtc`, `drivers/gpu/drm/drm_crtc.c:692-895`):**

| errno | Cause |
|---|---|
| `EOPNOTSUPP` | device has no `DRIVER_MODESET` |
| `ERANGE` | `x` or `y` above 0xffff (universal-plane src offsets are 16.16) |
| `ENOENT` | unknown CRTC id, unknown FB id, unknown connector id |
| `EACCES` | primary plane is leased by another master |
| `EINVAL` | aspect-ratio flag bits without `DRM_CLIENT_CAP_ASPECT_RATIO`; invalid mode; fb format not in the plane's format list; `count_connectors == 0` with a mode; `count_connectors > 0` with `mode == NULL` or `fb == NULL`; `count > num_connector` |
| `EFAULT` | connector id array unreadable |
| `ENOMEM` | connector array allocation failed |

Ordering constraints:

1. **`count` must match what you actually pass.** `SetCrtc(crtc, fb, 0, 0, &conn, 1, &mode)`
   is the "attach mode to this connector" form; passing `count = 0` with a
   mode is `EINVAL`.
2. **fb and mode are validated against each other.** The fb must have been
   created for a format the CRTC's primary plane accepts (`drm_plane_has_format`,
   `drm_crtc.c:774-782`). `DRM_FORMAT_XRGB8888` (§4.3) is the only safe choice
   for dumb buffers.
3. **`use-original-mode` needs a non-null original mode.** kmscon takes
   `original_mode` from the current CRTC, and if the CRTC was off (`mode_valid == 0`)
   that struct is all zeros; `use-original-mode` then asks for a 0×0 mode.
   kmshaunt must fall back to the preferred mode when
   `original_mode.hdisplay == 0` (kmscon's `is_mode_null`,
   `drm_shared.c:1334-1337`, is used for `default_mode`/`desired_mode` only, so
   this is a real kmscon edge case, not a design choice to copy).
4. **`use-original-mode` and `mode=` are mutually exclusive.** kmscon logs an
   error and clears `use-original-mode` (`config.c:1158-1165`, documented in
   `docs/reference/kmscon-options.md` §1, §5.3).
5. **Set the CRTC before the first page flip.** `DRM_IOCTL_MODE_PAGE_FLIP`
   requires the CRTC's primary plane to have a fb (`old_fb != NULL`, else
   `EBUSY`) and the CRTC to be active (`-EINVAL`, `page_flip_common`,
   `drivers/gpu/drm/drm_atomic_helper.c:3649-3654`).
6. **A mode change must be followed by a full redraw.** kmscon sets
   `DISPLAY_NEED_REDRAW` on every successful modeset
   (`drm_shared.c:935`, `drm2d_video.c:175-192`) and drops damage on that frame
   (`drm_display_set_damage`, `:816-818`).

---

## 4. Dumb buffers, mmap, framebuffers

### 4.1 Create

```c
/* xf86drmMode.h:515-518 */
extern int drmModeCreateDumbBuffer(int fd, uint32_t width, uint32_t height, uint32_t bpp,
                                   uint32_t flags, uint32_t *handle, uint32_t *pitch, uint64_t *size);
/* ioctl argument, drm_mode.h:1260-1268 */
struct drm_mode_create_dumb {
    __u32 height;   /* in */
    __u32 width;    /* in */
    __u32 bpp;      /* in: color mode, 32 = XRGB8888 family */
    __u32 flags;    /* in: must be zero */
    __u32 handle;   /* out */
    __u32 pitch;    /* out: bytes per line, may exceed width*4 */
    __u64 size;     /* out: bytes */
};
```

- `bpp = 32` and `flags = 0`. The header's table (`drm_mode.h:1229-1252`)
  documents that color mode 32 maps to `DRM_FORMAT_XRGB8888` "on their primary
  plane" for most drivers; kmscon hardcodes 32 (`init_rb`,
  `src/video/drm2d_video.c:61-70`).
- The returned `pitch` is authoritative and may be **larger** than `width*4`
  (driver alignment). Address rows with `pitch`, never `width*4`
  (`src/framebuffer.zig` already enforces this).
- Preconditions: `width != 0 && height != 0 && bpp != 0`; overflow-checked
  (`drm_dumb_buffers.c:78-98`). The ioctl needs **no master** (`drm_ioctl.c:636-637`).
- `DRM_CAP_DUMB_BUFFER` (0x1) must be 1, else the driver has no dumb support
  (`drm_ioctl.c:264-267`); kmscon refuses to init drm2d without it
  (`src/video/drm2d_video.c:286-290`). `drmGetCap` returns `-EOPNOTSUPP` for
  non-KMS devices (`drm_ioctl.c:258-260`).

**Errno:** `ENOSYS` (driver lacks `dumb_create`), `EINVAL` (zero size, bpp
overflow, or a driver-specific unsupported color mode), `ENOMEM`, plus whatever
the GEM allocator returns. QEMU std VGA does not restrict `bpp`; its
`DRM_GEM_VRAM_DRIVER` dumb_create computes `pitch = width * DIV_ROUND_UP(bpp,8)`
with no alignment (`drivers/gpu/drm/drm_gem_vram_helper.c:467-505`,
`include/drm/drm_gem_vram_helper.h:159-162`), so on bochs `pitch == width*4`
exactly for 32 bpp, while GEM-shmem drivers also return an unaligned minimum
(`drivers/gpu/drm/drm_gem_shmem_helper.c:492-509`). Drivers that do align
pitch will pad it; always use the returned value.

`DRM_CAP_DUMB_PREFERRED_DEPTH` (0x3) and `DRM_CAP_DUMB_PREFER_SHADOW` (0x4)
are hints only; QEMU std VGA reports `preferred_depth = 24`,
`prefer_shadow = 0` (`drivers/gpu/drm/tiny/bochs.c:543-544`). Do not derive
`bpp` from them — 32 is the scanout format you want.

### 4.2 Map

```c
/* xf86drmMode.h:537 */
extern int drmModeMapDumbBuffer(int fd, uint32_t handle, uint64_t *offset);
/* drm_mode.h:1272-1281 */
struct drm_mode_map_dumb { __u32 handle; __u32 pad; __u64 offset; };
```

Then:

```c
void *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, offset);
```

`offset` is a fake mmap offset for the DRM fd, not a physical address. No
master needed. `MAP_SHARED` is required so the kernel sees writes without
`msync`; flush with `memset`/store barriers is unnecessary for WB mappings on
x86 but do not use `MAP_PRIVATE`.

kmscon's exact order (`init_rb`, `drm2d_video.c:61-103`) is
**create → addfb2 → map_dumb → mmap → memset**, with the error path doing
`rmfb` + `destroy_dumb`. Note it creates the fb *before* mapping; both orders
work, but cleanup must be reverse.

### 4.3 Framebuffer: `AddFB` vs `AddFB2`

```c
/* xf86drmMode.h:296-298 */
extern int drmModeAddFB(int fd, uint32_t width, uint32_t height, uint8_t depth,
                        uint8_t bpp, uint32_t pitch, uint32_t bo_handle, uint32_t *buf_id);
/* xf86drmMode.h:300-303 */
extern int drmModeAddFB2(int fd, uint32_t width, uint32_t height,
                         uint32_t pixel_format, const uint32_t bo_handles[4],
                         const uint32_t pitches[4], const uint32_t offsets[4],
                         uint32_t *buf_id, uint32_t flags);
```

`drmModeAddFB` is compatibility sugar: the kernel maps `(bpp, depth)` to a
fourcc and then runs the AddFB2 path
(`drivers/gpu/drm/drm_framebuffer.c:117-146`). Mapping table
(`drm_mode_legacy_fb_format`, `drivers/gpu/drm/drm_fourcc.c:41-105`):

| bpp | depth | fourcc |
|---|---|---|
| 32 | 24 | `DRM_FORMAT_XRGB8888` |
| 32 | 30 | `DRM_FORMAT_XRGB2101010` |
| 32 | 32 | `DRM_FORMAT_ARGB8888` |
| 24 | 24 | `DRM_FORMAT_RGB888` |
| 16 | 16 | `DRM_FORMAT_RGB565` |
| 16 | 15 | `DRM_FORMAT_XRGB1555` |
| 8 | 8 | `DRM_FORMAT_C8` |

So the xrgb8888 back buffer is `AddFB(width, height, /*depth*/24, /*bpp*/32,
pitch, handle, &id)` — or, preferred, the explicit
`AddFB2(..., DRM_FORMAT_XRGB8888, {handle,0,0,0}, {pitch,0,0,0}, {0,0,0,0}, &id, 0)`
exactly as kmscon does (`drm_addfb2`, `drm2d_video.c:51-58`; args order matches
`drm_mode_fb_cmd2`, `drm_mode.h:704-737`).

Validation the kernel applies to AddFB2 (`framebuffer_check`,
`drm_framebuffer.c:154-266`), all `EINVAL` unless noted:

- pixel format must be a format the kernel knows (`__drm_format_info`),
- width/height non-zero and inside `mode_config.min/max` (EINVAL),
- each used plane needs a non-zero handle,
- `pitch >= drm_format_info_min_pitch` (for XRGB8888, `pitch >= width*4`),
- `height * pitch + offset` must fit in `UINT_MAX` → **`ERANGE`**,
- unused planes must have zero handles/pitches/offsets when
  `DRM_MODE_FB_MODIFIERS` is not set (it is not, for dumb buffers),
- flags other than `DRM_MODE_FB_INTERLACED (1<<0)` / `DRM_MODE_FB_MODIFIERS (1<<1)`
  are rejected; pass `flags = 0`.

AddFB/AddFB2 need **no master** (`drm_ioctl.c:630-631`) — convenient for
warming buffers up before taking master.

### 4.4 Destroy: order matters

```c
/* xf86drmMode.h:315, 322, 526 */
extern int drmModeRmFB(int fd, uint32_t bufferId);
extern int drmModeCloseFB(int fd, uint32_t buffer_id);   /* no plane disable */
extern int drmModeDestroyDumbBuffer(int fd, uint32_t handle);
```

- `DRM_IOCTL_MODE_RMFB` **disables the plane and may disable the CRTC** if the
  fb is in use (`drm.h:1224-1233`). Never rmfb the fb currently scanned out
  except when you intend to blank.
- `DRM_IOCTL_MODE_CLOSEFB` (newer UAPI; present by v6.10 and in libdrm 2.4.134,
  `drm.h:1340`) drops the
  user handle but keeps the fb alive while a plane uses it — use it for
  buffer swaps instead of rmfb if you cycle fbs.
- Correct teardown: `munmap` first, then `drmModeRmFB`, then
  `drmModeDestroyDumbBuffer` (kmscon `destroy_rb`, `drm2d_video.c:106-119`).
  Both ioctls return negative errno; log and continue on failure during
  teardown.
- Recreating buffers on every mode change is expected (kmscon frees in
  `display_freefb` when the display goes offline and reallocates in
  `display_allocfb`, `drm2d_video.c:121-152`).

### 4.5 Double buffering

kmscon keeps exactly two buffers per display and a `current_rb` index
(`struct drm2d_display`, `drm2d_internal.h:46-50`):

- `rb[0]`, `rb[1]`: `{ id, handle, stride, size, map }`.
- Draw into `rb[current_rb ^ 1]` (the back buffer) — `drm2d_display_blend`,
  `drm2d_render.c:44-118`; `drm2d_display_clear`, `:120-136`.
- On modeset, present `rb[current_rb ^ 1]` and flip `current_rb` only after
  success (`display_prepare_modeset`, `drm2d_video.c:155-173`;
  `display_done_modeset`, `:175-192`).
- On swap, `drm_display_swap(disp, rb[current_rb ^ 1].id)` then toggle
  (`drm2d_display_swap`, `drm2d_video.c:211-224`).

Two buffers are sufficient because a page flip is only submitted when the
previous one completed; a third buffer (triple buffering) is a latency
optimisation, not a correctness requirement, and it complicates the flip
accounting.

---

## 5. Page flips, events and the epoll loop

### 5.1 Submit

```c
/* xf86drmMode.h:429-430 */
extern int drmModePageFlip(int fd, uint32_t crtc_id, uint32_t fb_id,
                           uint32_t flags, void *user_data);
/* xf86drmMode.h:431-433 */
extern int drmModePageFlipTarget(int fd, uint32_t crtc_id, uint32_t fb_id,
                                 uint32_t flags, void *user_data, uint32_t target_vblank);
/* ioctl argument, drm_mode.h:1163-1169 */
struct drm_mode_crtc_page_flip {
    __u32 crtc_id; __u32 fb_id; __u32 flags; __u32 reserved; __u64 user_data;
};
```

`flags = DRM_MODE_PAGE_FLIP_EVENT` (`0x01`, `drm_mode.h:1108`) — the only flag
drm2d needs. `DRM_MODE_PAGE_FLIP_ASYNC` (`0x02`) tears and is rejected with
`EINVAL` unless `mode_config.async_page_flip` (`drm_plane.c:1381-1382`;
`DRM_CAP_ASYNC_PAGE_FLIP` 0x7 tells you if it is supported).
`DRM_MODE_PAGE_FLIP_TARGET_*` need `DRM_CAP_PAGE_FLIP_TARGET` and are pointless
here.

`user_data` is returned verbatim in the event; kmscon stores the `struct video
*` pointer, and because events can arrive after a display is unbound it
matches on `crtc_id` (`display_event`, `drm_shared.c:1106-1125`;
`page_flip_handler2`).

**Errno (`drm_mode_page_flip_ioctl`, `drivers/gpu/drm/drm_plane.c:1354-1551`,
and the header contract, `drm_mode.h:1139-1160`):**

| errno | Cause |
|---|---|
| `EOPNOTSUPP` | no `DRIVER_MODESET` |
| `EINVAL` | bad flag bits; `ASYNC` unsupported; `sequence != 0` without a target flag; both target flags; **fb format differs from the currently scanned-out fb** (`drm_plane.c:1483-1487`); CRTC not active (`page_flip_common`, `drm_atomic_helper.c:3649-3654`) |
| `ENOENT` | unknown CRTC or fb id |
| `EACCES` | primary plane leased |
| `EBUSY` | **a flip is already pending on that CRTC** (`drm_mode.h:1147-1149`), or the primary plane has no fb bound (`drm_plane.c:1446-1453`) |
| `ENOMEM` | event allocation |
| `EDEADLK` | modeset lock backoff; the kernel retries internally, you will not see it |

Both dumb buffers are created with the same fourcc, so the format-change
`EINVAL` cannot trigger — unless you ever switch one buffer to
`ARGB8888`/`RGB565`.

### 5.2 Event layout

```c
/* drm.h:1385-1388 (drm_event), drm.h:1417-1424 (drm_event_vblank) */
struct drm_event { __u32 type; __u32 length; };
struct drm_event_vblank {
    struct drm_event base;   /* type = DRM_EVENT_FLIP_COMPLETE (0x02) or DRM_EVENT_VBLANK (0x01) */
    __u64 user_data;
    __u32 tv_sec;
    __u32 tv_usec;
    __u32 sequence;
    __u32 crtc_id;           /* 0 on kernels without DRM_CAP_CRTC_IN_VBLANK_EVENT */
};
```

Verified layout (x86_64, §0.2): 32 bytes, `user_data` @8, `tv_sec` @16,
`tv_usec` @20, `sequence` @24, `crtc_id` @28.

`DRM_EVENT_VBLANK = 0x01`, `DRM_EVENT_FLIP_COMPLETE = 0x02`,
`DRM_EVENT_CRTC_SEQUENCE = 0x03` (`drm.h:1398-1415`). Timestamps are
`CLOCK_MONOTONIC` for kernels ≥ 4.15 (`DRM_CAP_TIMESTAMP_MONOTONIC` is always 1,
`drm.h:729-737`) — usable directly for frame pacing stats without clock
conversion.

### 5.3 Read with `drmHandleEvent`

```c
/* xf86drm.h:773-806 */
#define DRM_EVENT_CONTEXT_VERSION 4
typedef struct _drmEventContext {
    int version;
    void (*vblank_handler)(int fd, unsigned int sequence, unsigned int tv_sec, unsigned int tv_usec, void *user_data);
    void (*page_flip_handler)(int fd, unsigned int sequence, unsigned int tv_sec, unsigned int tv_usec, void *user_data);
    void (*page_flip_handler2)(int fd, unsigned int sequence, unsigned int tv_sec, unsigned int tv_usec, unsigned int crtc_id, void *user_data);
    void (*sequence_handler)(int fd, uint64_t sequence, uint64_t ns, uint64_t user_data);
} drmEventContext, *drmEventContextPtr;

extern int drmHandleEvent(int fd, drmEventContextPtr evctx);
```

Contract (implementation `xf86drmMode.c:1032-1098`):

- `read(fd, buf, 1024)`; the kernel guarantees whole events per read.
  `len == 0` → returns `0`; `len < sizeof(drm_event)` → returns `-1`.
- `page_flip_handler2` is called only when `evctx->version >= 3`; with
  `version = 4` and only `page_flip_handler2` set, `FLIP_COMPLETE` events take
  the crtc_id path and `vblank_handler`/`sequence_handler` are skipped when
  NULL. Set `version = DRM_EVENT_CONTEXT_VERSION` and
  `page_flip_handler2 = your_handler` (kmscon: `drm_video_read_events`,
  `drm_shared.c:1127-1146`).
- Up to 1024 bytes of events are consumed per call (32 events of
  `drm_event_vblank`); with `O_NONBLOCK` the next call returns `-1`/`EAGAIN`.
  kmscon tolerates `errno == EAGAIN` and treats other errors as fatal
  (`drm_shared.c:1139-1145`).
- The man page states the same return contract (`man/drmHandleEvent.3.rst`),
  but the implementation above is authoritative for the `EAGAIN` nuance.

### 5.4 epoll integration

kmscon's shape (`drm_video_init` `:1286`, `io_event` `:1160-1187`,
`drm_video_wait_pflip` `:1612-1650`):

1. Register the DRM fd `EV_READABLE` in the loop (level-triggered by default;
   the fd is `O_NONBLOCK`, so draining via `drmHandleEvent` until `EAGAIN` is
   safe).
2. On readable: call `drmHandleEvent` once (kernel batches), then run the
   per-display completion work.
3. kmscon defers the completion work to an idle callback (`do_pflips`,
   `:1148-1158`) so the flip callback cannot re-enter the video backend from
   inside the event reader.
4. On `EV_HUP | EV_ERR`: remove the fd from the loop and stop using the video
   device. The kernel does not deliver a null-event on unplug, so there is no
   graceful "device gone" event from `read` (kmscon's TODO at `:1131-1136`
   documents this).
5. For a synchronous wait (used before modeset and during wakeup), poll the fd
   with a bounded timeout and run the same reader
   (`drm_video_wait_pflip`, 1000 ms cap, adjusted across retries in
   `drm_display_wait_pflip`, `:835-859`).

### 5.5 Pacing state machine (what to implement)

Per display keep `flip_pending: bool` (kmscon's `DISPLAY_VSYNC`):

| State | Action |
|---|---|
| idle | draw back buffer, `drmModePageFlip(..., EVENT, user_data)`; on success set `flip_pending = true` |
| submitted | do not submit another flip — wait for `FLIP_COMPLETE`; with two buffers only one flip can be in flight, and the front buffer must not be written while the hardware may still scan it |
| `EBUSY` | keep `flip_pending` set: `EBUSY` means a flip is still pending from an earlier submit. Drop this frame and retry after `FLIP_COMPLETE`. kmscon refuses to submit when `DISPLAY_VSYNC` is set (`drm_display_swap`, `:1063-1088`) and suppresses the log for `EBUSY` in the atomic path (`:1050-1057`) |
| `FLIP_COMPLETE` | clear pending, swap front/back, notify the renderer (`drm_display_pflip`, `:1095-1104`) |

Never clear the pending flag on `EBUSY`; that is how you end up with two flips
queued for one CRTC and a permanently stuck frame loop.

---

## 6. Damage (`drmModeDirtyFB`, M8.2)

```c
/* xf86drmMode.h:126-127 */
typedef struct drm_clip_rect drmModeClip, *drmModeClipPtr;
/* drm.h:90-95 */
struct drm_clip_rect { unsigned short x1, y1, x2, y2; };
/* drm_mode.h:772-778 */
struct drm_mode_fb_dirty_cmd {
    __u32 fb_id; __u32 flags; __u32 color; __u32 num_clips; __u64 clips_ptr;
};
/* xf86drmMode.h:327-328 */
extern int drmModeDirtyFB(int fd, uint32_t bufferId, drmModeClipPtr clips, uint32_t num_clips);
```

- `drmModeClip` is `struct drm_clip_rect`: **`unsigned short`** coordinates,
  so damage rectangles clip at 65535 px, and `x2/y2` are **exclusive**
  (the kernel's own fbdev damage conversion does
  `drm_rect_init(clip, x1, y1, x2 - x1, y2 - y1)`,
  `drivers/gpu/drm/drm_fb_helper.c:671`).
- Max clips per call: `DRM_MODE_FB_DIRTY_MAX_CLIPS = 256` (`drm_mode.h:743`).
  More than that is `EINVAL` (`drm_framebuffer.c:743-747`).
- `flags` must be 0 (or `DRM_MODE_FB_DIRTY_ANNOTATE_COPY/FILL` with paired
  rects, `drm_mode.h:739-741`); `color` is used only with `ANNOTATE_FILL`.
- Requires **master** (`drm_ioctl.c:635`).

**Errno (`drm_mode_dirtyfb_ioctl`, `drivers/gpu/drm/drm_framebuffer.c:709-775`):**

| errno | Cause |
|---|---|
| `EOPNOTSUPP` | no `DRIVER_MODESET` |
| `ENOENT` | fb id unknown or not owned by this file |
| `EINVAL` | clips pointer/count mismatch (`!num_clips != !clips_ptr`), odd count with `ANNOTATE_COPY`, count > 256 |
| `EFAULT` | clip array unreadable |
| `ENOMEM` | clip copy allocation |
| `ENOSYS` | **the fb has no `->dirty` callback** (`if (fb->funcs->dirty) … else ret = -ENOSYS`) |

`ENOSYS` is the common case for dumb buffers: the generic GEM framebuffer funcs
have no `.dirty` (`drivers/gpu/drm/drm_gem_framebuffer_helper.c:255-258`), and
QEMU std VGA (`bochs`) creates fbs through `drm_gem_fb_create`
(`drivers/gpu/drm/tiny/bochs.c:522`). [Derived from those two files plus
`drm_framebuffer.c:762-767`.] So on the CI target expect `ENOSYS`; do not treat
it as a failure.

The header itself says the call is a hint: "The kernel or hardware is free to
update more then just the region specified … may also delay and/or coalesce
several calls" (`drm_mode.h:748-756`). Correct M8.2 policy:

1. After taking master, call `drmModeDirtyFB(fd, fb_id, NULL, 0)` once (both
   absent is valid: the kernel rejects only a mismatch, `drm_framebuffer.c:730-733`)
   and cache `supports_dirtyfb = rc == 0`. Treat `ENOSYS`/`EOPNOTSUPP` as "no
   damage support" and `EACCES` as "not master yet — probe again after
   `drmSetMaster`".
2. If supported, send coalesced damage rects for the *back* buffer right
   before the page flip. If not, skip the call and rely on the flip.
3. Never let damage skip rendering on a driver without support, and never send
   damage clipped to a stale buffer: the clip list refers to the fb being
   flipped.

**Atomic alternative (what kmscon actually does).** There is no
`drmModeDirtyFB` call anywhere in kmscon 10.1.0; its damage path is the
`FB_DAMAGE_CLIPS` plane property (`drm_shared.c:266-267`, `:621-627`). The blob
body is an array of `struct drm_mode_rect` (`s32`, half-open — `drm_mode.h:1520-1537`),
created with `drmModeCreatePropertyBlob(fd, rects, n*sizeof(rect), &blob_id)`
and destroyed with `drmModeDestroyPropertyBlob` after the commit
(`free_damage_blob`, `:677-684`). kmscon's `struct video_rect` is exactly
`drm_mode_rect`, and its producer writes `x2 = x1 + w` (`src/render/bbulk.c:632-635`).
kmshaunt's `Damage` (`src/framebuffer.zig`) is `{x,y,w,h}`, so convert once:
`x1=x, y1=y, x2=x+w, y2=y+h`.

Additional kmscon constraint worth copying: after a modeset, **do not** attach
damage clips (`if (disp->flags & DISPLAY_NEED_REDRAW) return;`,
`drm_shared.c:816-818`) — the blob would describe rows of the old mode.

---

## 7. DPMS

The control path is the connector's legacy `DPMS` enum property, values
`DRM_MODE_DPMS_ON=0`, `STANDBY=1`, `SUSPEND=2`, `OFF=3` (`drm_mode.h:143-146`),
enum names `"On" "Standby" "Suspend" "Off"` (`drivers/gpu/drm/drm_connector.c:992-997`).

### 7.1 Set

```c
/* xf86drmMode.h:421-422 */
extern int drmModeConnectorSetProperty(int fd, uint32_t connector_id,
                                       uint32_t property_id, uint64_t value);
```

Discovery, exactly as kmscon does it (`drm_set_dpms`, `drm_shared.c:718-761`):

1. `drmModeGetConnector(fd, conn_id)` → `count_props`, `props[]`.
2. For each `props[i]`: `drmModeGetProperty(fd, props[i])`, `strcmp(prop->name, "DPMS")`.
3. On match: `drmModeConnectorSetProperty(fd, conn_id, prop->prop_id, value)`,
   then `drmModeFreeProperty`.
4. No match → the connector has no DPMS; report `Unsupported` and keep a
   software-blank fallback (kmscon returns `DPMS_UNKNOWN`, `:755-759`).

`drmModeConnectorSetProperty` is `DRM_IOCTL_MODE_SETPROPERTY`, which requires
**master** (`drm_ioctl.c:626`) and is implemented as
`drm_mode_obj_set_property_ioctl` with `obj_type = DRM_MODE_OBJECT_CONNECTOR`
(`drm_connector.c:3082-3095`). The kernel handles `DPMS` itself by calling
`connector->funcs->dpms` (`drm_connector.c:3071-3078`); for atomic drivers the
core remaps DPMS onto the linked CRTC's `ACTIVE` property
(`drm_connector.c:1298-1305`).

The property is **legacy-uAPI only**: writing `DPMS` through
`drmModeAtomicCommit`/atomic property blobs is rejected with `EINVAL` — "legacy
[PROP:DPMS] can only be set via legacy uAPI"
(`drivers/gpu/drm/drm_atomic_uapi.c:687-695`). So DPMS always goes through
`drmModeConnectorSetProperty`, even on an otherwise atomic backend.

**Errno:** `EINVAL` (property not on this connector, unknown object, bad
value), `ENOENT` (unknown connector), `EACCES` (not master), `ENOMEM`.

### 7.2 Ordering constraints

1. **Only set DPMS when the connector is enabled.** Kernel documentation is
   explicit: "Only set DPMS when the connector is known to be enabled, assume
   that a successful SETCONFIG call also sets DPMS to on, and never read back
   the value of DPMS because it can be incorrect"
   (`drivers/gpu/drm/drm_connector.c:1326-1328`).
2. **`SetCrtc` forces DPMS to ON** (`drm_connector.c:1322-1324`). A modeset
   therefore invalidates any "screen is off" bookkeeping; re-apply DPMS after
   the modeset if you need it off.
3. **DPMS Off can make page flips fail.** The core documents that for atomic
   drivers the legacy `DPMS` property remaps to the `ACTIVE` property of the
   linked CRTC (`drm_connector.c:1298-1305`), and a flip on an inactive CRTC is
   rejected with `EINVAL` (`page_flip_common`,
   `drivers/gpu/drm/drm_atomic_helper.c:3649-3654`).
   kmscon avoids the question by refusing swaps while off (`drm_display_swap`,
   `drm_shared.c:1068`). On wake, do a full modeset/commit before
   flipping, not just a flip.
4. **Never probe DPMS with `drmModeGetConnector` during a blank cycle** unless
   you are master; the read is fine but the value may be stale (§7.3).

### 7.3 Read-back and tests

Two independent read paths, with different reliability:

- **Connector property**: `conn->prop_values[i]` for the `DPMS` prop
  (`drm_get_dpms`, `drm_shared.c:763-785`). Can be stale on legacy drivers
  (kernel warning above).
- **sysfs**: `/sys/class/drm/cardN-<CONNECTOR>/dpms`, e.g.
  `/sys/class/drm/card0-HDMI-A-1/dpms`. It is a **read-only** attribute
  (`DEVICE_ATTR_RO(dpms)`, `drivers/gpu/drm/drm_sysfs.c:239-248, 305`) that
  prints `connector->dpms` via `drm_get_dpms_name`, i.e. one of
  `On\n`, `Standby\n`, `Suspend\n`, `Off\n`. This is the oracle ROADMAP M5.6
  uses ("The connector's sysfs `dpms` file reads `Off` after the timeout and
  `On` after a keypress"); it is not a control interface, and on non-atomic
  drivers it lags reality too.

kmscon's `dpms-timeout` behaviour, for parity (`seat.c:456-481`, `:483-514`,
default 600 s, `0` disables — `docs/reference/kmscon-options.md` §1, §5.8):

- idle timer per seat; on expiry, DPMS `Off` on every activated display and
  deactivate the terminal session;
- any input clears the blank: DPMS `On` on the same displays, reactivate the
  terminal, reset the timer;
- both directions are skipped when the seat is not awake/foreground — so a VT
  switch does not blank, and a blanked seat does not stay blanked across a
  switch.

---

## 8. Hardware cursor

Two acceptable implementations. kmscon prefers the universal cursor plane when
one exists and falls back to legacy `SETCURSOR` otherwise; on QEMU std VGA
there is no cursor plane at all (`bochs` uses `drm_simple_display_pipe`, which
creates only a primary plane — `drivers/gpu/drm/tiny/bochs.c:92, 550`), so the
software cursor is the CI path.

### 8.1 Legacy calls

```c
/* xf86drmMode.h:354-360 */
int drmModeSetCursor(int fd, uint32_t crtcId, uint32_t bo_handle, uint32_t width, uint32_t height);
int drmModeSetCursor2(int fd, uint32_t crtcId, uint32_t bo_handle, uint32_t width, uint32_t height, int32_t hot_x, int32_t hot_y);
int drmModeMoveCursor(int fd, uint32_t crtcId, int x, int y);
```

Wrappers (`xf86drmMode.c:437-482`) send `DRM_MODE_CURSOR_BO` (`0x01`) with the
GEM **handle** (not a fb id), and `DRM_MODE_CURSOR_MOVE` (`0x02`) for position.
`drmModeSetCursor` is `drmModeSetCursor2` with hotspot `(0,0)` (the kernel
copies the legacy struct into the new one, `drm_plane.c:1329-1339`).
`handle = 0` turns the cursor off (`drm_plane.c:1297-1303`).

**The format is fixed on atomic drivers:** `DRM_FORMAT_ARGB8888`. When the
CRTC has a universal cursor plane the kernel wraps the handle itself with
`pixel_format = DRM_FORMAT_ARGB8888` and
`pitch = width * 4` (`drm_mode_cursor_universal`, `drm_plane.c:1168-1194`);
drivers with a true legacy `cursor_set`/`cursor_set2` define their own format,
but every modern driver expects ARGB8888 there too.
Consequence: the dumb buffer you pass **must have `pitch == width*4`**, or the
wrapped fb describes different rows than the buffer holds. Check the returned
pitch and, if it differs, use the universal path (§8.2) instead.

**Hotspot needs the cap:** `hot_x/hot_y` land in the plane's `HOTSPOT_X/Y`
properties, and the kernel hides virtualized cursor planes unless
`DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT` was set (§1.5). kmscon sets the cap at
init and only then trusts the hotspot (`drm_shared.c:1283-1284`,
`cursor_hotspot`). With the cap absent, treat the hotspot as `(0,0)`.

**Errno (`drm_mode_cursor_common`, `drm_plane.c:1249-1326`):** `EOPNOTSUPP`
(no KMS), `EINVAL` (no flags, unknown flag bits, or the plane rejects the
size/format), `ENOENT` (unknown CRTC), `EACCES` (lease), `ENXIO` (legacy CRTC
with neither `cursor_set` nor `cursor_set2`), `EFAULT` (move on a CRTC without
`cursor_move`). Requires **master** (`drm_ioctl.c:618`, `:641`).

### 8.2 Universal cursor plane recipe

```c
/* xf86drmMode.h:435-442 */
extern drmModePlaneResPtr drmModeGetPlaneResources(int fd);
extern drmModePlanePtr drmModeGetPlane(int fd, uint32_t plane_id);
extern int drmModeSetPlane(int fd, uint32_t plane_id, uint32_t crtc_id, uint32_t fb_id,
                           uint32_t flags, int32_t crtc_x, int32_t crtc_y,
                           uint32_t crtc_w, uint32_t crtc_h,
                           uint32_t src_x, uint32_t src_y, uint32_t src_w, uint32_t src_h);
```

1. `DRM_CLIENT_CAP_UNIVERSAL_PLANES` must already be set (§1.5), else the
   cursor plane is not listed at all (`drm_plane.c:792-799`).
2. `drmModeGetPlaneResources`, then for each plane `drmModeGetPlane` +
   `drmModeObjectGetProperties(fd, plane_id, DRM_MODE_OBJECT_PLANE)`.
3. Read the `"type"` property value; `DRM_PLANE_TYPE_CURSOR == 2`
   (`xf86drmMode.h:225-227`). Accept the plane only when
   `plane->possible_crtcs & (1 << crtc_index)` (kmscon `modeset_find_plane`,
   `drm_shared.c:230-292`).
4. Create a dumb buffer + `AddFB2` with `DRM_FORMAT_ARGB8888` at the cursor
   size (kmscon `cursor_create_buffer`, `drm_shared.c:338-387`).
5. Position with `drmModeSetPlane(plane_id, crtc_id, fb_id, 0,
   x - hot_x, y - hot_y, w, h, 0, 0, w << 16, h << 16)`. **Source
   coordinates are 16.16 fixed point**, destination is signed pixels; a
   negative `crtc_x` legally clips the cursor at the screen edge
   (`drm_mode.h:296-311`).
6. Hide with `fb_id = 0` (or `crtc_id = 0`); kmscon disables `FB_ID` and
   `CRTC_ID` for both cursor and overlay planes when leaving a VT, because a
   compositor can otherwise leave a cursor mid-screen
   (`modeset_clear_cursor_and_overlays`, `drm_shared.c:297-336`).

`DRM_IOCTL_MODE_SETPLANE` requires **master** (`drm_ioctl.c:617`) and returns
negative errno: `EINVAL` (plane/crtc incompatible, bad src rect, format not in
`plane->formats`), `ENOENT` (unknown ids), `EACCES` (lease).

### 8.3 Size from caps

```c
/* xf86drm.h:611 */
uint64_t w = 0, h = 0;
if (drmGetCap(fd, DRM_CAP_CURSOR_WIDTH,  &w) < 0) return error.Unsupported;
if (drmGetCap(fd, DRM_CAP_CURSOR_HEIGHT, &h) < 0) return error.Unsupported;
```

`DRM_CAP_CURSOR_WIDTH/HEIGHT` are 0x8/0x9 (`drm.h:756-767`), and the kernel
returns **64** when the driver never set `mode_config.cursor_width/height`
(`drm_ioctl.c:285-295`). A 64×64 answer therefore does *not* prove a cursor
plane exists — check the plane first, as kmscon does (`if
(!ddrm->cursor_plane.id) return -EOPNOTSUPP;`, `drm_shared.c:415-416`). kmscon
then clamps to `VIDEO_CURSOR_MAX_SIZE` (64, `src/video/video.h:159`) and copies
the overlapping top-left region without scaling (`copy_w/copy_h = min(...)`,
`drm_shared.c:401-455`).

### 8.4 Fallback

If the plane is missing, the cap call fails, or `SetPlane` returns
`EOPNOTSUPP`/`EINVAL`/`ENOSYS`, report `error.Unsupported` from
`Backend.setCursor` (`src/video.zig`) so the renderer composites the cursor.
That is what `soft-cursor` forces (kmscon `--soft-cursor`, default off,
`config.c:1026`; `docs/reference/kmscon-options.md` §1).

---

## 9. Hotplug

### 9.1 Kernel side: exactly two uevent shapes

- Card-level: `kobject_uevent_env(&dev->primary->kdev->kobj, KOBJ_CHANGE, "HOTPLUG=1")`
  (`drivers/gpu/drm/drm_sysfs.c:441-450`, `drm_sysfs_hotplug_event`).
- Connector-level (newer UAPI): `KOBJ_CHANGE` with **both**
  `HOTPLUG=1` and `CONNECTOR=<connector object id>`
  (`drm_sysfs_connector_hotplug_event`, `drm_sysfs.c:460-475`).

Both arrive as udev action `change`. There is no "hotplug" action.

### 9.2 udev wiring (kmscon's `uterm_monitor`)

`src/uterm/monitor.c` is a small, complete reference:

1. `udev_monitor_new_from_netlink(udev, "udev")`.
2. Filters: subsystem `drm` **devtype `drm_minor`** (this selects the per-card
   device nodes; connector sysfs children are not matched by it),
   plus `graphics` and `input` (`:534-556`).
3. `udev_monitor_enable_receiving`, `udev_monitor_get_fd`, set `O_NONBLOCK`,
   register the fd `EV_READABLE` (`:552-595`).
4. Drain loop: `udev_monitor_receive_device` until NULL, then dispatch on
   `udev_device_get_action`: `add` → `monitor_udev_add`, `remove` →
   `monitor_udev_remove`, `change` → `monitor_udev_change`
   (`monitor_udev_event`, `:470-500`).
5. `change` handling: if the device belongs to another seat, remove+re-add;
   otherwise re-read the `HOTPLUG` property and, when it is `"1"`, invoke the
   hotplug callback (`monitor_udev_change`, `:442-468`). **Matching on
   `HOTPLUG=1` is what filters the many unrelated `change` events** (rfkill,
   backlight, …).
6. Initial state comes from `udev_enumerate` with the same subsystem filters
   (`uterm_monitor_scan`, `:638-712`); the callback stream is identical, so
   there is one code path for "found at boot" and "plugged later".
7. Device identity and flags are computed at add time: `get_card_id` requires
   sysname `card<digits>` (`:128`); `ID_SEAT` defaults to `seat0`;
   `ID_PATH` is kept for stable display naming; primary/aux flags come from
   `get_drm_flags` (§10) — and note it **opens the node** read-write for that
   probe (`O_RDWR|O_CLOEXEC`, `:330-350`), which is harmless and does not take
   master.

kmscon's response to a hotplug event is not a full reinit: the seat marks the
video device "needs poll" and calls `video_poll`
(`seat_monitor_hotplug_dev` → `kmscon_seat_poll_video`, `seat.c:668-674` and `:1025-1033`),
which runs `drm_video_hotplug(fd, read_dpms=false, modeset=false)`; the
enumerate/bind branch inside decides whether a modeset is needed
(`drm_shared.c:1456-1553`). That is the pattern to copy: **hotplug is a
re-enumeration trigger, not a device reopen**.

### 9.3 Re-enumeration algorithm (must be idempotent)

From `drm_video_hotplug` (`drm_shared.c:1456-1553`):

1. `drmModeGetResources`.
2. Clear "available" on every known display.
3. For each `res->connectors[i]`: `drmModeGetConnector`; skip unless
   `connection == DRM_MODE_CONNECTED && count_modes > 0`.
4. Known display → mark available; if `read_dpms`, compare DPMS and re-apply
   on change; if it was not online, request a modeset.
5. Unknown connector → bind (new display object, `bind_display`,
   `:1392-1454`) and request a modeset.
6. Unbind displays that were not marked available.
7. No displays left → `drmDropMaster`.
8. If a modeset is needed → mode search + `SetCrtc` for all displays
   (`try_modeset`, `:977-1016`, with a retry using the default mode on
   `-EAGAIN`).

Consequences: a hotplug event during an active flip must not free the display
until the flip completes (kmscon takes a ref for the pending flip,
`drm_display_swap`, `:1083-1087`, and releases it in the event handler). And a
DPMS change event (`read_dpms = true`) happens only on wake/hotplug paths,
never in the fast frame loop.

### 9.4 Known gaps

- The kernel's in-kernel polling (`drm_kms_helper_poll`) is what generates
  these uevents for drivers with poll support; a driver with `poll=0` and no
  HPD interrupt sends nothing. Keep a slow safety re-probe (kmshaunt already
  has a timerfd in `src/loop.zig`); kmscon has no such fallback.
- `udev_device_get_property_value(dev, "HOTPLUG")` relies on systemd-udev's
  property propagation; if kmshaunt ever runs without udev, hotplug must be
  polled. That is out of scope for M1/M5 (libudev is in D3).

---

## 10. Multi-GPU: `gpus=`, node kinds, per-card state

### 10.1 Option semantics (parity)

`gpus=` accepts `all` (default), `aux`/`auxiliary`, `primary`/`single`
(`config.c:466-485`; `KMSCON_GPU_ALL/AUX/PRIMARY`, `config.h:41-45`;
documented in `docs/reference/kmscon-options.md` §1, §5.8). Filtering
(`kmscon_seat_gpu_is_ignored`, `seat.c:850-894`):

| Mode | Accept |
|---|---|
| `all` | primary + auxiliary + anything else |
| `aux` | devices flagged primary **or** auxiliary |
| `primary` | only devices flagged primary |

Flags are computed once per udev add (`src/uterm/monitor.c:232-259`,
`:309-350`):

- **PCI primary:** parent PCI device's `boot_vga` sysfs attribute == `"1"`.
- **Platform primary:** no PCI parent, no USB ancestor, has a `platform`
  parent (SoC display controllers). USB-attached displays are never primary.
- **Auxiliary:** DRM driver name is `"udl"` (read via `DRM_IOCTL_VERSION`, which
  kmscon hand-copies to avoid a build-time libdrm dependency in `uterm`,
  `monitor.c:262-306`).
- fbdev devices are additionally flagged `DRM_BACKED` by inspecting
  `FBIOGET_FSCREENINFO` `id` for a `drmfb` suffix (so `drm=true` can skip
  them) and `AUX` for `udlfb`, `PRIMARY` for `VESA VGA` (`:190-230`).

Note the asymmetry: in `all`/`aux` mode, **unflagged** DRM devices are included
by `all` but excluded by `aux`; only `primary` requires the flag. This is what
"aux" means — "primary or auxiliary".

### 10.2 Node kind: `cardN` vs `renderDN`

```c
/* xf86drm.h:598-600 */
#define DRM_NODE_PRIMARY 0
#define DRM_NODE_CONTROL 1   /* deprecated, never returned */
#define DRM_NODE_RENDER  2
extern int drmGetNodeTypeFromFd(int fd);      /* xf86drm.h:814; -1/errno */
extern int drmGetDevices2(uint32_t flags, drmDevicePtr devices[], int max_devices); /* :926 */
```

`drmGetDevices2` gives, per card, `nodes[DRM_NODE_MAX]` and an
`available_nodes` bitmask (`available_nodes & (1 << DRM_NODE_PRIMARY)`), which
is the clean enumeration API if you do not want udev. kmscon does not use it;
it enumerates via udev and opens `vid->node` directly.

**Render nodes cannot modeset.** Every KMS ioctl's permission entry is either
`DRM_MASTER` (SETCRTC, SETPLANE, PAGE_FLIP, DIRTYFB, CURSOR/CURSOR2,
SETPROPERTY, ATOMIC) or has no `DRM_RENDER_ALLOW` bit, and
`drm_ioctl_permit` returns `EACCES` for a render client whenever
`DRM_RENDER_ALLOW` is missing (`drivers/gpu/drm/drm_ioctl.c:543-565`):

```c
if (unlikely(!(flags & DRM_RENDER_ALLOW) && drm_is_render_client(file_priv)))
    return -EACCES;
```

Consequences:

- drm2d opens `cardN` (primary node) only.
- `drmSetMaster` on `renderDN` fails (`SET_MASTER` has flags 0 → render clients
  hit the `EACCES` branch above, and `drm_master_check_perm` would fail too).
- drm3d (M5.1) needs a second, separate fd for GBM/EGL on the same card. The
  GBM/EGL fd is typically the **render node**, while modeset stays on the
  primary fd; buffer sharing between them is by dma-buf/PRIME, not by GEM
  handle. Keep the two fds in the card's state, never mix GEM handles across
  them (libdrm's `drmPrimeFDToHandle` warning, `xf86drm.h:818-833`).

### 10.3 Per-card state

Master is per DRM device, not per system: two cards can each have a different
master. So the master state machine of §1.4 is instantiated **per card**, and a
VT switch must acquire/release master on every open card. kmscon models this as
one `struct video` per device (`seat_video_init`, `seat.c:899-948`; the seat
loops over `seat->videos` on wake/sleep, `seat.c:158-213`). A hotplug `remove`
tears down only the matching `video` (`kmscon_seat_remove_video`, `seat.c:997-1023`).

`gpus=` changes how many `video` instances exist; it never merges cards into
one backend. The layout layer (`src/video/layout.zig`) is what combines
per-connector outputs, with `multi-monitor=clone|largest|scaled` (default
`scaled`, `config.c:1057`) and `screen=` rotation/disable
(`docs/reference/kmscon-options.md` §5.4, §5.8).

---

## 11. Compact drm2d frame loop

Zig-flavoured pseudocode against the contract in `src/video.zig`. Error paths
elided; every `try` maps to the errno tables above. Ordering is the point.

```zig
// ---- init (once per card, after the VT is in KD_GRAPHICS) ----
const fd = try openCard("card0");                    // O_RDWR|O_CLOEXEC|O_NONBLOCK
_ = drmSetMaster(fd);                                 // EBUSY → retry in 50ms; EACCES → fail
try setClientCaps(fd);                                // UNIVERSAL_PLANES, (ATOMIC), CURSOR_HOTSPOT(optional)

const res = drmModeGetResources(fd) orelse return error.GetResourcesFailed;
var chosen: ?Conn = null;
for (res.connectors[0..res.count_connectors]) |cid| {
    const conn = drmModeGetConnector(fd, cid) orelse continue;    // forced probe works: master
    defer drmModeFreeConnector(conn);
    if (conn.connection != DRM_MODE_CONNECTED or conn.count_modes == 0) continue;
    // copy by value: the connector is freed at the end of this iteration
    if (chosen == null or isPreferred(conn))
        chosen = Conn{ .conn_id = conn.connector_id, .mode = pickMode(conn) };
}
const c = chosen orelse return error.NoConnectedDisplay;

const crtc = try findCrtc(fd, res, c);                // encoder_id → crtc_id, else possible_crtcs
const plane = try findPrimaryPlane(fd, crtc.index);   // needs UNIVERSAL_PLANES
const cursor_plane = try findCursorPlane(fd, crtc.index); // null on bochs → software cursor

// two buffers at the chosen mode
var bufs: [2]Buf = undefined;
for (&bufs) |*b| {
    try dbCreate(fd, c.mode.hdisplay, c.mode.vdisplay, 32, &b.handle, &b.pitch, &b.size);
    try fbAdd2(fd, c.mode.hdisplay, c.mode.vdisplay, DRM_FORMAT_XRGB8888,
               b.handle, b.pitch, &b.fb);                      // depth24/bpp32
    try dbMap(fd, b.handle, &b.offset);
    b.map = try mmap(b.size, fd, b.offset);           // MAP_SHARED|PROT_READ|WRITE
    @memset(b.map, 0);
}
var front: u1 = 0;
try setCrtc(fd, crtc.id, bufs[front].fb, &c.conn_id, &c.mode);   // fb0 on screen, DPMS forced On
var dirtyfb_supported = probeDirtyFb(fd, bufs[0].fb);  // ENOSYS/EOPNOTSUPP → false

// ---- steady-state loop (one epoll thread, D2) ----
while (running) {
    // 1. epoll wait: DRM fd, udev monitor fd, timerfd, signalfd, pty, input, …
    if (drm_fd.readable) {
        var ev = drmEventContext{ .version = DRM_EVENT_CONTEXT_VERSION, .page_flip_handler2 = onFlip };
        _ = drmHandleEvent(fd, &ev);                  // -1 + EAGAIN is normal (O_NONBLOCK)
    }
    // onFlip(fd, seq, sec, usec, crtc_id, user_data):
    //     d.pending = false;
    //     front ^= 1; free damage list; wake renderer;

    if (d.pending or dpms != .on) continue;           // pace on vblank; never flip while off
    if (no terminal damage for this frame) { maybeBlankAfterTimeout(); continue; }

    const back = bufs[front ^ 1];
    renderInto(back.map, back.pitch, damage);         // CPU renderer, damage-tracked rows
    if (dirtyfb_supported) {
        const clips = damageToClipRects(damage);      // u16, x2/y2 exclusive, ≤256
        _ = drmModeDirtyFB(fd, back.fb, clips.ptr, clips.len);  // hint; ignore errors
    }
    const rc = drmModePageFlip(fd, crtc.id, back.fb, DRM_MODE_PAGE_FLIP_EVENT, null);
    if (rc == 0) d.pending = true;                    // flip queued; wait for FLIP_COMPLETE
    else if (rc == -EBUSY) { /* an earlier flip is still pending; retry next loop */ }
    else if (rc == -EINVAL) { /* CRTC inactive (DPMS off) or mode change: full modeset first */ }
    else return error.FlipFailed;
}

// ---- VT switch away ----
waitPendingFlips(fd, 1000);                           // bounded poll + drmHandleEvent
clearCursorAndOverlays(fd);                           // atomic commit or keep planes hidden
_ = drmDropMaster(fd);                                // before allowing the VT switch
// VT switch back: drmSetMaster, re-enumerate (hotplug path), SetCrtc, full redraw

// ---- teardown ----
_ = drmDropMaster(fd);
for (&bufs) |*b| { munmap(b.map, b.size); _ = drmModeRmFB(fd, b.fb); _ = drmModeDestroyDumbBuffer(fd, b.handle); }
drmModeFreeCrtc(crtc); drmModeFreePlane(plane); drmModeFreeResources(res);
```

Notes on the shape:

- The render and flip are one frame apart by construction: you always draw the
  buffer that is not being scanned out, and you only submit after the previous
  `FLIP_COMPLETE`.
- `drmModeDirtyFB` sits **between** rendering and the flip so the driver can
  start the copy as early as possible; it is advisory (§6).
- Do not `drmModeSetCrtc` on every frame. It is synchronous and kills the flip
  pipeline; only modeset changes and DPMS-on transitions need it.
- The loop must never block on a pending flip; a blocked loop stops reading
  input and the flip event that would unblock it.

---

## 12. The ordering constraints that actually bite

Ordered by how expensive the resulting bug is.

| # | Constraint | Violation consequence |
|---|---|---|
| 1 | `KD_GRAPHICS` **before** the first `SetCrtc` | console keeps blitting over the scanout; flicker and ghost text |
| 2 | `drmDropMaster` **before** allowing the VT switch (`VT_RELDISP`) | the next DRM owner's `drmSetMaster` fails `EBUSY` (`drm_auth.c:260-263`); a compositor cannot start |
| 3 | `drmSetMaster` **before** the first connector probe | forced probe is demoted to read-only for non-master (`drm_connector.c:3189-3197`); connectors report `count_modes == 0` and get skipped |
| 4 | One outstanding `PageFlip` per CRTC; clear the pending flag only on `FLIP_COMPLETE` | second flip in flight → `EBUSY`; if the flag is cleared on `EBUSY` the loop queues flips it never waits for and the frame pacing collapses |
| 5 | `SetCrtc` (full modeset) before any flip on a CRTC, and after DPMS-on | flips on an inactive CRTC fail `EINVAL` (`page_flip_common`, `drm_atomic_helper.c:3649-3654`) |
| 6 | Never change fb fourcc across flips | flip `EINVAL` (`drm_plane.c:1483-1487`) |
| 7 | `DRM_CLIENT_CAP_UNIVERSAL_PLANES` before `GetPlaneResources`, `DRM_CLIENT_CAP_ATOMIC` before `CURSOR_PLANE_HOTSPOT` | only overlay planes listed (`drm_plane.c:792-799`); hotspot cap returns `EINVAL` (`drm_ioctl.c:366-369`); cursor plane hidden on virtio/qxl (`drm_plane.c:801-812`) |
| 8 | Find the cursor plane before trusting `DRM_CAP_CURSOR_WIDTH/HEIGHT` | caps report 64 even with no cursor plane (`drm_ioctl.c:285-295`); `SetCursor` fails or does nothing visible |
| 9 | Cursor dumb buffer pitch must equal `width*4` when using legacy `SetCursor` | universal cursor path wraps the handle with `pitch = width*4` (`drm_plane.c:1168-1174`); padded dumb pitch shears the image |
| 10 | Damage rects are half-open and must describe the fb being flipped; none after a modeset | off-by-one artifacts, or a blob describing the previous mode's rows (kmscon clears damage on `NEED_REDRAW`, `drm_shared.c:816-818`) |
| 11 | Damage/`DirtyFB` is advisory; `ENOSYS` is normal | treating `ENOSYS` as fatal disables drm2d on QEMU std VGA |
| 12 | Free the display only after its flip completes | use-after-free in the event handler; kmscon refs the display for the flip (`drm_shared.c:1083-1087`) and matches events by `crtc_id` |
| 13 | Teardown order `munmap` → `RmFB` → `DestroyDumb` | `RmFB` on a bound fb disables the plane/CRTC (`drm.h:1224-1233`); destroying the dumb handle first leaks or faults |
| 14 | Hotplug only re-enumerates; it never reopens the fd or re-takes master mid-stream | losing master on a spurious reinit; unbinding displays that are mid-flip |

---

## 13. Deliberately out of scope

- Atomic commits (`drmModeAtomicCommit`) beyond the two uses kmscon makes of
  them (initial modeset with `ALLOW_MODESET`, flips with `PageFlip` +
  `NONBLOCK`, damage blobs). M1.3 is a legacy modeset backend; the atomic
  variant belongs to the drm3d/shared path if M5 needs it.
- Gamma (`drmModeCrtcSetGamma`), leases, writeback connectors, rotation
  properties (`ROTATE_*` plane properties are the atomic route for `screen=`
  rotation; legacy `SetCrtc` cannot rotate).
- PRIME/dma-buf interop between the drm2d primary fd and a drm3d render fd;
  §10.2 only records the constraint that they are different fds.