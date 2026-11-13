//! src/video/drm2d.zig -- DRM dumb-buffer video backend (ROADMAP M1.3, M5
//! video parity, M8.2 damage-only presentation).
//!
//! Implements the `video.Backend` vtable on top of libdrm's legacy KMS path:
//! dumb buffers + mmap, `drmModeSetCrtc` modesets, event-driven page flips,
//! connector `DPMS` property, legacy hardware cursor. Atomic commits are
//! deliberately out of scope (recipes §13); drm3d owns that path.
//!
//! Every call recipe, struct layout and ordering constraint comes from
//! docs/reference/drm2d-recipes.md (libdrm 2.4.134, Linux v6.12). Constraint
//! numbers below refer to its §12 table.
//!
//! ## Device seam (DrmOps)
//!
//! All device access goes through `DrmOps`, a struct of function pointers at
//! the libdrm call level (plus open/close/mmap/munmap/read/poll). `Drm2d.init`
//! takes the ops, so tests inject a fake device and run hermetically; the
//! production implementation is `libdrm.ops()`, a thin wrapper over the
//! translated C API. The `drm-c` module is imported lazily inside that
//! namespace only, so this file compiles and tests without libdrm present.
//!
//! The translate-c shim (ROADMAP D3, module name `drm-c`):
//!
//!     #include <xf86drm.h>
//!     #include <xf86drmMode.h>
//!
//! Both include directories are required: xf86drm.h includes <drm.h> and
//! xf86drmMode.h includes <drm.h>/<drm_mode.h>/<drm_fourcc.h>, which live in
//! include/libdrm/ (recipes §0):
//!
//!     const drm_c = b.addTranslateC(.{ .root_source_file = b.path("src/drm-c.h"), ... });
//!     drm_c.addIncludePath(.{ .cwd_relative = "<libdrm-dev>/include" });
//!     drm_c.addIncludePath(.{ .cwd_relative = "<libdrm-dev>/include/libdrm" });
//!     exe.root_module.addImport("drm-c", drm_c.createModule());
//!     exe.root_module.linkSystemLibrary("drm", .{});
//!
//! ## Tests
//!
//! Hermetic (fake DrmOps, no libdrm, no device):
//!
//!     nix run nixpkgs#zig -- test src/test_drm2d.zig
//!
//! (src/test_drm2d.zig is the src-level test root: `zig test` rejects imports
//! outside the root file's module path, so the root must sit above video/.)
//!
//! Real wrapper + ABI checks against the pinned libdrm (adds -lc, which the
//! in-file `link_libc` test gate uses to reference the libdrm namespace):
//!
//!     DEV=$(nix build nixpkgs#libdrm.dev --print-out-paths --no-link)
//!     zig translate-c src/drm-c.h -I$DEV/include -I$DEV/include/libdrm -lc > /tmp/drm_c.zig
//!     nix run nixpkgs#zig -- test --dep drm-c -Mroot=src/test_drm2d.zig \
//!         -Mdrm-c=/tmp/drm_c.zig -lc -I$DEV/include -I$DEV/include/libdrm \
//!         -L$DEV/lib -ldrm
//!
//! ## Ordering constraints enforced here (recipes §12)
//!
//!  - #2  dropMaster before the VT switch: `dropMaster` waits for in-flight
//!        flips and hides the cursor, then drops; the seat calls it before
//!        VT_RELDISP.
//!  - #3  master before forced probe: init enumerates read-only
//!        (GetConnectorCurrent, no master needed); `takeMaster` re-enumerates
//!        with forced probe once master is held.
//!  - #4  one outstanding flip: `endFrame` refuses while pending; EBUSY keeps
//!        the pending flag set; only FLIP_COMPLETE clears it (`readEvents`).
//!  - #5  SetCrtc before any flip and after DPMS-on: `setMode` modesets before
//!        buffers can flip; `setDpms(.on)` re-runs SetCrtc.
//!  - #6  both dumb buffers use XRGB8888 (depth 24 / bpp 32), never mixed.
//!  - #7  UNIVERSAL_PLANES set at init before any plane work; legacy path
//!        skips ATOMIC (recipes §1.5 note).
//!  - #8/#9 cursor size from caps, legacy SetCursor2 requires pitch == w*4;
//!        any failure permanently falls back to error.Unsupported.
//!  - #10 damage describes the fb being flipped, half-open u16 clips, none on
//!        the first frame after a modeset (`full_redraw`).
//!  - #11 DirtyFB is advisory; ENOSYS/EOPNOTSUPP disable it, never fatal.
//!  - #12 buffers are never freed under a pending flip (setMode, connectors,
//!        deinit all wait or defer).
//!  - #13 teardown per buffer: munmap -> RmFB -> DestroyDumb, then close.
//!  - #14 connectors() only re-enumerates; it never reopens the fd or retakes
//!        master.
//!
//! #1 (KD_GRAPHICS before first SetCrtc) is the seat's job (src/seat.zig);
//! this backend only requires that the caller took master first.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const video = @import("../video.zig");
const fb = @import("../framebuffer.zig");

pub const Framebuffer = fb.Framebuffer;
pub const Damage = fb.Damage;
pub const Mode = video.Mode;
pub const ConnectorInfo = video.ConnectorInfo;
pub const DpmsState = video.DpmsState;

const page_align = std.heap.page_size_min;

/// DRM constants used by the legacy path (values verified against the pinned
/// headers, recipes §0.2/§4/§5/§7/§8).
pub const drm = struct {
    // DRM_CAP_* (drm.h)
    pub const CAP_DUMB_BUFFER: u64 = 0x1;
    pub const CAP_CURSOR_WIDTH: u64 = 0x8;
    pub const CAP_CURSOR_HEIGHT: u64 = 0x9;
    // DRM_CLIENT_CAP_* (drm.h)
    pub const CLIENT_CAP_UNIVERSAL_PLANES: u64 = 2;
    // DRM_EVENT_* (drm.h)
    pub const EVENT_VBLANK: u32 = 0x01;
    pub const EVENT_FLIP_COMPLETE: u32 = 0x02;
    // DRM_MODE_PAGE_FLIP_EVENT (drm_mode.h)
    pub const PAGE_FLIP_EVENT: u32 = 0x01;
    // DRM_MODE_TYPE_PREFERRED (drm_mode.h)
    pub const MODE_TYPE_PREFERRED: u32 = 1 << 3;
    // DRM_MODE_DPMS_* (drm_mode.h)
    pub const DPMS_ON: u64 = 0;
    pub const DPMS_STANDBY: u64 = 1;
    pub const DPMS_SUSPEND: u64 = 2;
    pub const DPMS_OFF: u64 = 3;
    // DRM_MODE_FB_DIRTY_MAX_CLIPS (drm_mode.h)
    pub const FB_DIRTY_MAX_CLIPS: usize = 256;
    // DRM_FORMAT_* (drm_fourcc.h)
    pub const FORMAT_XRGB8888: u32 = 0x34325258;
    pub const FORMAT_ARGB8888: u32 = 0x34324152;
    // DRM_MODE_OBJECT_* (drm_mode.h:624-633)
    pub const OBJECT_PLANE: u32 = 0xeeeeeeee;
    // DRM_PLANE_TYPE_* (xf86drmMode.h:225-227)
    pub const PLANE_TYPE_OVERLAY: u32 = 0;
    pub const PLANE_TYPE_PRIMARY: u32 = 1;
    pub const PLANE_TYPE_CURSOR: u32 = 2;
};

/// `drmModeModeInfo` (drm_mode.h:221-244), copied verbatim from the connector
/// mode list and passed back to SetCrtc without modification (recipes §3).
/// extern layout matches libdrm exactly: 68 bytes, name at offset 36.
pub const ModeInfo = extern struct {
    /// Pixel clock in kHz.
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    /// Approximate refresh in Hz (kernel-computed; may be 0 for user modes).
    vrefresh: u32,
    flags: u32,
    type: u32,
    name: [32]u8,

    pub fn isPreferred(self: ModeInfo) bool {
        return self.type & drm.MODE_TYPE_PREFERRED != 0;
    }
};

/// `struct drm_clip_rect` (drm.h:90-95): u16 coordinates, x2/y2 exclusive
/// (recipes §6).
pub const Clip = extern struct {
    x1: u16,
    y1: u16,
    x2: u16,
    y2: u16,
};

/// `drmModeConnection` (xf86drmMode.h:190-194).
pub const Connection = enum(u32) {
    connected = 1,
    disconnected = 2,
    unknown = 3,
};

/// Snapshot of `drmModeRes`, owned (allocator-backed copies of the arrays).
pub const Resources = struct {
    crtcs: []u32,
    connectors: []u32,
    encoders: []u32,
    min_width: u32,
    max_width: u32,
    min_height: u32,
    max_height: u32,

    pub fn deinit(self: *Resources, allocator: Allocator) void {
        allocator.free(self.crtcs);
        allocator.free(self.connectors);
        allocator.free(self.encoders);
        self.* = undefined;
    }
};

pub const PropValue = struct { id: u32, value: u64 };

/// Snapshot of `drmModeConnector`, owned. The real ops copy out of the
/// libdrm-allocated struct and free it before returning (two-phase
/// GetConnector dance happens inside libdrm, recipes §2.2).
pub const Connector = struct {
    connector_id: u32,
    encoder_id: u32,
    connector_type: u32,
    connector_type_id: u32,
    connection: Connection,
    mm_width: u32,
    mm_height: u32,
    modes: []ModeInfo,
    props: []PropValue,
    encoders: []u32,

    pub fn deinit(self: *Connector, allocator: Allocator) void {
        allocator.free(self.modes);
        allocator.free(self.props);
        allocator.free(self.encoders);
        self.* = undefined;
    }
};

/// Snapshot of `drmModeEncoder` (small, returned by value).
pub const Encoder = struct {
    encoder_id: u32,
    encoder_type: u32,
    crtc_id: u32,
    /// Bitmask of CRTC *indices* into Resources.crtcs, not IDs.
    possible_crtcs: u32,
    possible_clones: u32,
};

/// Name/id/flags of a `drmModeProperty`; enough for DPMS discovery.
pub const Property = struct {
    prop_id: u32,
    flags: u32,
    name: [32]u8,

    pub fn nameSlice(self: *const Property) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

/// Snapshot of `drmModeCrtc` (recipes §2.4): enough to recover the mode a
/// connector is currently driven at (`use-original-mode`). `buffer_id` 0
/// means no fb is bound (off / disconnected).
pub const CrtcState = struct {
    crtc_id: u32,
    buffer_id: u32,
    width: u32,
    height: u32,
    mode_valid: bool,
    mode: ModeInfo,
};

/// Snapshot of `drmModePlaneRes` (recipes §2.5), owned.
pub const PlaneResources = struct {
    planes: []u32,

    pub fn deinit(self: *PlaneResources, allocator: Allocator) void {
        allocator.free(self.planes);
        self.* = undefined;
    }
};

/// Snapshot of `drmModePlane` (recipes §2.5). `possible_crtcs` is a bitmask
/// of CRTC *indices* into Resources.crtcs, like Encoder.possible_crtcs.
pub const Plane = struct {
    plane_id: u32,
    crtc_id: u32,
    fb_id: u32,
    possible_crtcs: u32,
};

/// Snapshot of `drmModeObjectProperties` (recipes §2.5), owned. Used to read
/// a plane's "type" property when looking for a cursor plane.
pub const ObjectProperties = struct {
    props: []PropValue,

    pub fn deinit(self: *ObjectProperties, allocator: Allocator) void {
        allocator.free(self.props);
        self.* = undefined;
    }
};

/// Result of CREATE_DUMB: pitch is authoritative and may exceed width*4
/// (recipes §4.1).
pub const DumbBuffer = struct { handle: u32, pitch: u32, size: u64 };

/// The device seam. Every function takes the opaque `ctx` first (the fake
/// device's state pointer; null for the real libdrm ops). Errors are Zig
/// errors: the KMS negative-errno family and the core -1/errno family are
/// both mapped by the real wrapper (recipes §0.1):
///
///   EACCES -> AccessDenied, EBUSY -> Busy, ENOENT -> NotFound,
///   ENOSYS/EOPNOTSUPP -> Unsupported, EINVAL -> InvalidArgument,
///   ENOMEM -> OutOfMemory, EAGAIN -> WouldBlock, else -> DrmCallFailed.
pub const DrmOps = struct {
    ctx: ?*anyopaque = null,

    // -- device node and master (xf86drm.c family) --
    /// Open a primary node O_RDWR|O_CLOEXEC|O_NONBLOCK (recipes §1.1).
    open: *const fn (ctx: ?*anyopaque, path: [*:0]const u8) anyerror!i32,
    close: *const fn (ctx: ?*anyopaque, fd: i32) void,
    set_master: *const fn (ctx: ?*anyopaque, fd: i32) anyerror!void,
    drop_master: *const fn (ctx: ?*anyopaque, fd: i32) anyerror!void,
    is_master: *const fn (ctx: ?*anyopaque, fd: i32) anyerror!bool,
    get_cap: *const fn (ctx: ?*anyopaque, fd: i32, cap: u64, value: *u64) anyerror!void,
    set_client_cap: *const fn (ctx: ?*anyopaque, fd: i32, cap: u64, value: u64) anyerror!void,

    // -- enumeration (NULL+errno family, copied into owned snapshots) --
    get_resources: *const fn (ctx: ?*anyopaque, fd: i32, allocator: Allocator) anyerror!Resources,
    /// force_probe=true is drmModeGetConnector (EDID reprobe, needs master);
    /// false is drmModeGetConnectorCurrent (read-only, no master needed).
    get_connector: *const fn (ctx: ?*anyopaque, fd: i32, allocator: Allocator, connector_id: u32, force_probe: bool) anyerror!Connector,
    get_encoder: *const fn (ctx: ?*anyopaque, fd: i32, encoder_id: u32) anyerror!Encoder,
    get_property: *const fn (ctx: ?*anyopaque, fd: i32, prop_id: u32) anyerror!Property,

    // -- modeset / buffers / flips (negative-errno family) --
    /// mode=null with empty connector_ids disables the CRTC.
    set_crtc: *const fn (ctx: ?*anyopaque, fd: i32, crtc_id: u32, fb_id: u32, x: u32, y: u32, connector_ids: []const u32, mode: ?*const ModeInfo) anyerror!void,
    create_dumb: *const fn (ctx: ?*anyopaque, fd: i32, width: u32, height: u32, bpp: u32) anyerror!DumbBuffer,
    map_dumb: *const fn (ctx: ?*anyopaque, fd: i32, handle: u32) anyerror!u64,
    destroy_dumb: *const fn (ctx: ?*anyopaque, fd: i32, handle: u32) anyerror!void,
    add_fb: *const fn (ctx: ?*anyopaque, fd: i32, width: u32, height: u32, depth: u8, bpp: u8, pitch: u32, handle: u32) anyerror!u32,
    rm_fb: *const fn (ctx: ?*anyopaque, fd: i32, fb_id: u32) anyerror!void,
    /// Advisory damage hint; empty clips = full-frame probe (recipes §6).
    dirty_fb: *const fn (ctx: ?*anyopaque, fd: i32, fb_id: u32, clips: []const Clip) anyerror!void,
    page_flip: *const fn (ctx: ?*anyopaque, fd: i32, crtc_id: u32, fb_id: u32, flags: u32, user_data: u64) anyerror!void,
    connector_set_property: *const fn (ctx: ?*anyopaque, fd: i32, connector_id: u32, prop_id: u32, value: u64) anyerror!void,
    set_cursor2: *const fn (ctx: ?*anyopaque, fd: i32, crtc_id: u32, handle: u32, width: u32, height: u32, hot_x: i32, hot_y: i32) anyerror!void,
    move_cursor: *const fn (ctx: ?*anyopaque, fd: i32, crtc_id: u32, x: i32, y: i32) anyerror!void,

    // -- current CRTC / universal planes (optional; recipes §2.4/§2.5/§8.2) --
    // Null when the seam implementation does not provide them; the backend
    // then degrades (no current-mode detection, no cursor-plane discovery).
    /// Current CRTC state for use-original-mode (drmModeGetCrtc).
    get_crtc: ?*const fn (ctx: ?*anyopaque, fd: i32, crtc_id: u32) anyerror!CrtcState = null,
    /// Universal plane list (drmModeGetPlaneResources); needs UNIVERSAL_PLANES.
    get_plane_resources: ?*const fn (ctx: ?*anyopaque, fd: i32, allocator: Allocator) anyerror!PlaneResources = null,
    /// One plane (drmModeGetPlane).
    get_plane: ?*const fn (ctx: ?*anyopaque, fd: i32, plane_id: u32) anyerror!Plane = null,
    /// An object's property values (drmModeObjectGetProperties).
    object_get_properties: ?*const fn (ctx: ?*anyopaque, fd: i32, allocator: Allocator, object_id: u32, object_type: u32) anyerror!ObjectProperties = null,

    // -- syscalls --
    /// MAP_SHARED|PROT_READ|PROT_WRITE at the fake mmap offset from map_dumb.
    mmap: *const fn (ctx: ?*anyopaque, fd: i32, len: usize, offset: u64) anyerror![]align(page_align) u8,
    munmap: *const fn (ctx: ?*anyopaque, mem: []align(page_align) u8) void,
    /// Nonblocking read of the event fd; error.WouldBlock when drained.
    read: *const fn (ctx: ?*anyopaque, fd: i32, buf: []u8) anyerror!usize,
    /// Wait for readability (POLLIN) up to timeout_ms.
    poll: *const fn (ctx: ?*anyopaque, fd: i32, timeout_ms: i32) anyerror!void,
};

/// Connector type name, matching libdrm's drmModeGetConnectorTypeName
/// (xf86drmMode.c:1784-1835) so names agree with /sys/class/drm spelling.
pub fn connectorTypeName(connector_type: u32) ?[]const u8 {
    return switch (connector_type) {
        0 => "Unknown",
        1 => "VGA",
        2 => "DVI-I",
        3 => "DVI-D",
        4 => "DVI-A",
        5 => "Composite",
        6 => "SVIDEO",
        7 => "LVDS",
        8 => "Component",
        9 => "DIN",
        10 => "DP",
        11 => "HDMI-A",
        12 => "HDMI-B",
        13 => "TV",
        14 => "eDP",
        15 => "Virtual",
        16 => "DSI",
        17 => "DPI",
        18 => "Writeback",
        19 => "SPI",
        20 => "USB",
        else => null,
    };
}

// ---------------------------------------------------------------------------
// GPU selection (`--gpus=all|primary|aux`, ROADMAP M5.3, recipes §10.1).
//
// The policy filter is pure and hermetically tested; `enumerateGpus` is the
// production sysfs scanner that classifies each /dev/dri/cardN. The backend
// itself opens one card; the caller (main.zig) uses these to choose which
// card path(s) to open.
// ---------------------------------------------------------------------------

/// `--gpus` policy (kmscon config.c:466-498). Mirrors config.Gpus without
/// importing the config module, keeping the backend independent.
pub const GpuSelection = enum { all, primary, aux };

/// A candidate DRM primary node. `primary`/`aux` are the kmscon udev flags
/// (recipes §10.1): PCI `boot_vga` / platform SoC primary, and `udl` USB
/// auxiliary. `path`/`name` borrow the caller's storage or the allocator.
pub const GpuCandidate = struct {
    path: []const u8,
    name: []const u8,
    primary: bool = false,
    aux: bool = false,
};

/// Whether a card is ignored under the policy (kmscon
/// `kmscon_seat_gpu_is_ignored`, recipes §10.1): `all` keeps everything;
/// `primary` keeps only primary cards; `aux` keeps primary OR aux cards.
/// Note the asymmetry: an unflagged card is kept by `all` but dropped by
/// `aux`.
pub fn gpuIgnored(primary: bool, aux: bool, policy: GpuSelection) bool {
    return switch (policy) {
        .all => false,
        .primary => !primary,
        .aux => !(primary or aux),
    };
}

/// Copy the candidates accepted by `policy` into `out` (caller-provided,
/// ideally at least `candidates.len`), preserving order, and return the kept
/// slice. Allocation-free; entries beyond `out.len` are dropped.
pub fn selectGpus(candidates: []const GpuCandidate, policy: GpuSelection, out: []GpuCandidate) []GpuCandidate {
    var n: usize = 0;
    for (candidates) |c| {
        if (gpuIgnored(c.primary, c.aux, policy)) continue;
        if (n < out.len) out[n] = c;
        n += 1;
    }
    return out[0..@min(n, out.len)];
}

/// Scan /dev/dri for primary nodes (cardN, not renderDN) and classify each
/// via sysfs (recipes §10.1). Best effort: a card whose sysfs attributes
/// cannot be read is returned unflagged. The returned slice and its strings
/// are allocator-owned; free with `freeGpuCandidates`.
pub fn enumerateGpus(allocator: Allocator) ![]GpuCandidate {
    var list: std.ArrayList(GpuCandidate) = .empty;
    errdefer {
        for (list.items) |c| {
            allocator.free(c.path);
            allocator.free(c.name);
        }
        list.deinit(allocator);
    }
    var dir = std.fs.cwd().openDir("/dev/dri", .{ .iterate = true }) catch
        return list.toOwnedSlice(allocator);
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (!isCardName(ent.name)) continue;
        const path = try std.fmt.allocPrint(allocator, "/dev/dri/{s}", .{ent.name});
        errdefer allocator.free(path);
        const name = try allocator.dupe(u8, ent.name);
        errdefer allocator.free(name);
        const flags = classifyCard(allocator, ent.name);
        try list.append(allocator, .{
            .path = path,
            .name = name,
            .primary = flags.primary,
            .aux = flags.aux,
        });
    }
    std.mem.sort(GpuCandidate, list.items, {}, struct {
        fn lt(_: void, a: GpuCandidate, b: GpuCandidate) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return list.toOwnedSlice(allocator);
}

/// Free a slice returned by `enumerateGpus`.
pub fn freeGpuCandidates(allocator: Allocator, candidates: []GpuCandidate) void {
    for (candidates) |c| {
        allocator.free(c.path);
        allocator.free(c.name);
    }
    allocator.free(candidates);
}

/// cardN: "card" followed by one or more decimal digits (excludes renderDN).
fn isCardName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "card")) return false;
    const digits = name["card".len..];
    if (digits.len == 0) return false;
    for (digits) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Classify a card from sysfs (recipes §10.1): PCI `boot_vga == 1` or a
/// platform (SoC) display controller is primary; the `udl` driver is aux;
/// USB-attached displays are never primary.
fn classifyCard(allocator: Allocator, name: []const u8) struct { primary: bool, aux: bool } {
    var primary = false;
    var aux = false;
    const dev = std.fmt.allocPrint(allocator, "/sys/class/drm/{s}/device", .{name}) catch
        return .{ .primary = primary, .aux = aux };
    defer allocator.free(dev);

    if (readSysfsAttr(allocator, dev, "boot_vga")) |v| {
        defer allocator.free(v);
        if (std.mem.eql(u8, std.mem.trim(u8, v, " \t\r\n"), "1")) primary = true;
    } else |_| {}

    // Bus classification from the device symlink target.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = std.fs.cwd().readLink(dev, &link_buf) catch "";
    const is_usb = std.mem.indexOf(u8, real, "usb") != null;
    const is_platform = std.mem.indexOf(u8, real, "platform") != null;
    if (!is_usb and is_platform) primary = true;

    if (readSysfsAttr(allocator, dev, "uevent")) |v| {
        defer allocator.free(v);
        var lines = std.mem.splitScalar(u8, v, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "DRIVER=")) {
                if (std.mem.eql(u8, line["DRIVER=".len..], "udl")) aux = true;
            }
        }
    } else |_| {}

    if (is_usb) primary = false;
    return .{ .primary = primary, .aux = aux };
}

/// Read `<dir>/<attr>` into an allocator-owned slice; error when absent.
fn readSysfsAttr(allocator: Allocator, dir_path: []const u8, attr: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, attr });
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, 4096);
}

fn dpmsValue(state: DpmsState) u64 {
    return switch (state) {
        .on => drm.DPMS_ON,
        .standby => drm.DPMS_STANDBY,
        .suspend_ => drm.DPMS_SUSPEND,
        .off => drm.DPMS_OFF,
    };
}

/// Convert a DRM mode to the contract's Mode. Refresh is computed exactly
/// from clock/htotal/vtotal in millihertz (vrefresh is approximate, §3);
/// physical size comes from the connector, not the mode (recipes §2.2).
fn toVideoMode(m: ModeInfo, mm_width: u32, mm_height: u32) Mode {
    var refresh_mhz: u32 = m.vrefresh *| 1000;
    const htotal: u64 = m.htotal;
    const vtotal: u64 = m.vtotal;
    if (m.clock > 0 and htotal > 0 and vtotal > 0) {
        const mhz = @as(u64, m.clock) * 1_000_000 / (htotal * vtotal);
        refresh_mhz = @intCast(@min(mhz, std.math.maxInt(u32)));
    }
    return .{
        .width_px = m.hdisplay,
        .height_px = m.vdisplay,
        .refresh_mhz = refresh_mhz,
        .width_mm = mm_width,
        .height_mm = mm_height,
    };
}

/// Per-connector state kept between enumerations. `info_modes` and `name`
/// are borrowed by the ConnectorInfo slice handed to callers.
const Conn = struct {
    id: u32,
    connector_type: u32,
    type_id: u32,
    connected: bool,
    mm_width: u32,
    mm_height: u32,
    encoder_id: u32,
    encoders: []u32,
    modes: []ModeInfo,
    info_modes: []Mode,
    name: []u8,
    dpms_prop_id: ?u32,
    /// Index into `modes` of the mode the connector is currently driven at,
    /// recovered from its bound CRTC (use-original-mode); null when unknown.
    current_mode: ?usize = null,

    fn deinit(self: *Conn, allocator: Allocator) void {
        allocator.free(self.encoders);
        allocator.free(self.modes);
        allocator.free(self.info_modes);
        allocator.free(self.name);
        self.* = undefined;
    }
};

fn freeConns(allocator: Allocator, conns: []Conn) void {
    for (conns) |*c| c.deinit(allocator);
    allocator.free(conns);
}

/// One scanout buffer: dumb handle + fb id + mmap + the contract view.
const Buffer = struct {
    handle: u32,
    fb_id: u32,
    size: u64,
    map: []align(page_align) u8,
    view: Framebuffer,
};

/// Legacy cursor image buffer (no fb id: SetCursor2 takes the GEM handle).
const CursorBuffer = struct {
    handle: u32,
    size: u64,
    width: u32,
    height: u32,
    pitch: u32,
    map: []align(page_align) u8,
};

/// A discovered cursor plane: its id and the CRTC-*index* bitmask it can
/// drive (same convention as Encoder.possible_crtcs).
const CursorPlane = struct { id: u32, possible_crtcs: u32 };

const Crtc = struct { id: u32, index: usize };

/// The DRM dumb-buffer backend. One instance per card (master is per device,
/// recipes §10.3); M1.3 drives the first connected connector.
///
/// Lifecycle: init (open, enumerate read-only, pick connector+mode) ->
/// takeMaster (seat activate) -> setMode -> frame loop (beginFrame/endFrame,
/// readEvents on fd readability) -> dropMaster (seat deactivate) -> deinit.
pub const Drm2d = struct {
    allocator: Allocator,
    ops: DrmOps,
    fd: i32,
    card_path: []u8,
    card_name: []u8,
    master: bool = false,

    resources: Resources,
    conns: []Conn,
    infos: []ConnectorInfo,
    /// Index into conns of the first connected connector found at init.
    chosen: ?usize,

    active: ?Active = null,
    bufs: [2]Buffer = undefined,
    bufs_live: bool = false,
    /// Index of the buffer currently scanned out.
    front: u1 = 0,
    /// Constraint #4: set on successful submit (or EBUSY), cleared only by
    /// FLIP_COMPLETE in readEvents.
    flip_pending: bool = false,
    /// Buffer index the in-flight flip will make front.
    flipping_to: u1 = 0,
    /// Constraint #10: first frame after a modeset presents without damage.
    full_redraw: bool = true,

    dpms: DpmsState = .on,
    dirtyfb_supported: bool = false,

    cursor_w: ?u32,
    cursor_h: ?u32,
    /// Cursor planes discovered at init (id + possible_crtcs bitmask).
    /// supportsHwCursor is true only when one can drive the active CRTC
    /// (constraint #8: caps alone do not prove a cursor plane exists).
    cursor_planes: []CursorPlane,
    /// Permanent software fallback after a SetCursor2 device failure.
    hw_cursor_failed: bool = false,
    /// `--soft-cursor` (M5.7): force the software cursor even with a plane.
    force_soft_cursor: bool = false,
    cursor_buf: ?CursorBuffer = null,
    /// Hotplug event source (M5.5), created by enableHotplug.
    hotplug: ?Hotplug = null,

    /// Cookie returned verbatim in flip events; matched together with
    /// crtc_id so events for other CRTCs (or after unbind) are ignored.
    const flip_cookie: u64 = 0x4B4D_5348_4155_4E54; // "KMSHAUNT"

    const Active = struct {
        connector_id: u32,
        mode_idx: usize,
        crtc_id: u32,
        crtc_index: usize,
        mode: ModeInfo,
    };

    /// Open the card and enumerate. `card_path` null selects /dev/dri/card0
    /// (udev enumeration lands with M5 hotplug; recipes §9.4). Master is NOT
    /// taken here: the seat calls `takeMaster` on activate (constraint #3 is
    /// honored by re-probing there). Returns error.NoConnectedDisplay when
    /// no connected connector has modes, error.Unsupported when the driver
    /// has no dumb-buffer support (kmscon drm2d_video.c:286-290).
    pub fn init(allocator: Allocator, card_path: ?[]const u8, ops: DrmOps) !*Drm2d {
        const path = card_path orelse "/dev/dri/card0";
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);

        const fd = try ops.open(ops.ctx, path_z.ptr);
        errdefer ops.close(ops.ctx, fd);

        // Client caps before enumeration (recipes §1.5). Universal planes
        // exposes cursor/primary planes; the legacy path skips ATOMIC, and a
        // failure here is a normal outcome, not an error.
        ops.set_client_cap(ops.ctx, fd, drm.CLIENT_CAP_UNIVERSAL_PLANES, 1) catch {};

        var value: u64 = 0;
        try ops.get_cap(ops.ctx, fd, drm.CAP_DUMB_BUFFER, &value);
        if (value != 1) return error.Unsupported;

        const cursor_w = capOptional(ops, fd, drm.CAP_CURSOR_WIDTH);
        const cursor_h = capOptional(ops, fd, drm.CAP_CURSOR_HEIGHT);
        const cursor_planes = try detectCursorPlanes(allocator, ops, fd);
        errdefer allocator.free(cursor_planes);

        // Owned copies: ConnectorInfo.card_name borrows from card_path, so
        // it must not point into the caller's string.
        const card_path_owned = try allocator.dupe(u8, path);
        errdefer allocator.free(card_path_owned);
        const card_name_owned = try allocator.dupe(u8, std.fs.path.basename(path));
        errdefer allocator.free(card_name_owned);

        var resources = try ops.get_resources(ops.ctx, fd, allocator);
        errdefer resources.deinit(allocator);
        // Read-only probe: no master yet, forced probe would be demoted
        // (constraint #3); takeMaster re-enumerates with force_probe=true.
        const conns = try enumerateConnectors(allocator, ops, fd, &resources, false);
        errdefer freeConns(allocator, conns);
        const infos = try buildInfos(allocator, conns, card_path_owned);
        errdefer allocator.free(infos);

        const chosen = for (conns, 0..) |c, i| {
            if (c.connected and c.modes.len > 0) break i;
        } else null;
        if (chosen == null) return error.NoConnectedDisplay;

        const self = try allocator.create(Drm2d);
        self.* = .{
            .allocator = allocator,
            .ops = ops,
            .fd = fd,
            .card_path = card_path_owned,
            .card_name = card_name_owned,
            .resources = resources,
            .conns = conns,
            .infos = infos,
            .chosen = chosen,
            .cursor_w = cursor_w,
            .cursor_h = cursor_h,
            .cursor_planes = cursor_planes,
        };
        return self;
    }

    /// Release everything: wait for in-flight flips, tear down the cursor,
    /// drop master, then per buffer munmap -> RmFB -> DestroyDumb
    /// (constraint #13), free enumeration state, close the fd.
    pub fn deinit(self: *Drm2d) void {
        // Constraint #12: never free buffers under a pending flip.
        if (self.flip_pending) self.waitFlip() catch {};
        self.cursorTeardown();
        if (self.hotplug) |*h| h.deinit();
        self.allocator.free(self.cursor_planes);
        self.ops.drop_master(self.ops.ctx, self.fd) catch {};
        self.destroyBuffers();
        freeConns(self.allocator, self.conns);
        self.allocator.free(self.infos);
        self.resources.deinit(self.allocator);
        self.allocator.free(self.card_path);
        self.allocator.free(self.card_name);
        self.ops.close(self.ops.ctx, self.fd);
        self.allocator.destroy(self);
    }

    /// The contract vtable view.
    pub fn backend(self: *Drm2d) video.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The DRM fd, for `Loop.addSource(fd, ev.in_, handler, userdata)`. On
    /// readability the handler must call `readEvents`; on HUP/ERR stop using
    /// the device (recipes §5.4). The fd is O_NONBLOCK.
    pub fn eventFd(self: *const Drm2d) i32 {
        return self.fd;
    }

    // ------------------------------------------------------------------
    // Master handoff (seat coordination, constraints #2/#3)
    // ------------------------------------------------------------------

    /// Take DRM master (seat activate). EBUSY means another owner holds the
    /// screen: the seat retries on its 50 ms timer (recipes §1.4). After
    /// taking master, re-enumerate with forced EDID probe and re-apply the
    /// modeset: another owner may have reprogrammed the CRTC while we were
    /// away (recipes §1.3 step 7).
    pub fn takeMaster(self: *Drm2d) !void {
        if (self.master) return;
        const already = self.ops.is_master(self.ops.ctx, self.fd) catch false;
        if (!already) try self.ops.set_master(self.ops.ctx, self.fd);
        self.master = true;
        _ = try self.connectors();
        if (self.active) |act| {
            if (self.bufs_live) {
                try self.ops.set_crtc(self.ops.ctx, self.fd, act.crtc_id, self.bufs[self.front].fb_id, 0, 0, &.{act.connector_id}, &act.mode);
                self.full_redraw = true;
                if (self.dpms != .on) try self.applyDpms(self.dpms);
            }
        }
    }

    /// Drop DRM master (seat deactivate, before VT_RELDISP — constraint #2).
    /// Waits for pending flips and hides the cursor first (recipes §1.4).
    /// EINVAL on drop means "already dropped" and is treated as success
    /// (recipes §1.2).
    pub fn dropMaster(self: *Drm2d) !void {
        if (!self.master) return;
        if (self.flip_pending) self.waitFlip() catch {};
        if (self.supportsHwCursor() and self.active != null) self.setCursor(null, 0, 0) catch {};
        self.ops.drop_master(self.ops.ctx, self.fd) catch |err| switch (err) {
            error.InvalidArgument => {},
            else => return err,
        };
        self.master = false;
    }

    pub fn isMaster(self: *const Drm2d) bool {
        return self.master;
    }

    // ------------------------------------------------------------------
    // Enumeration
    // ------------------------------------------------------------------

    /// Re-probe connectors (hotplug refresh). Constraint #14: this only
    /// re-enumerates — never reopens the fd or retakes master. As master the
    /// probe is forced (EDID re-read); otherwise read-only. An active
    /// connector that vanished is torn down, unless a flip is still in
    /// flight (constraint #12: teardown deferred to the next call).
    pub fn connectors(self: *Drm2d) ![]const ConnectorInfo {
        var new_res = try self.ops.get_resources(self.ops.ctx, self.fd, self.allocator);
        errdefer new_res.deinit(self.allocator);
        const new_conns = try enumerateConnectors(self.allocator, self.ops, self.fd, &new_res, self.master);
        errdefer freeConns(self.allocator, new_conns);
        const new_infos = try buildInfos(self.allocator, new_conns, self.card_path);
        errdefer self.allocator.free(new_infos);

        self.resources.deinit(self.allocator);
        freeConns(self.allocator, self.conns);
        self.allocator.free(self.infos);
        self.resources = new_res;
        self.conns = new_conns;
        self.infos = new_infos;

        if (self.active) |act| {
            const idx = self.connIndex(act.connector_id);
            const still_connected = if (idx) |i| self.conns[i].connected else false;
            if (idx) |i| self.infos[i].current_mode = act.mode_idx;
            if (!still_connected and !self.flip_pending) {
                self.destroyBuffers();
                self.active = null;
            }
        }
        return self.infos;
    }

    fn connIndex(self: *const Drm2d, connector_id: u32) ?usize {
        for (self.conns, 0..) |c, i| {
            if (c.id == connector_id) return i;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Modeset
    // ------------------------------------------------------------------

    /// Modeset connector `connector_idx` to `mode_idx` (indices into the
    /// last connectors() result). Recreates the double-buffer pair at the
    /// new size and runs SetCrtc before any flip can happen (constraint #5).
    /// SetCrtc forces DPMS on, so a tracked non-on state is re-applied
    /// afterwards (recipes §7.2.2). Requires master (takeMaster first).
    pub fn setMode(self: *Drm2d, connector_idx: usize, mode_idx: usize) !void {
        if (connector_idx >= self.conns.len) return error.InvalidConnector;
        const conn = &self.conns[connector_idx];
        if (!conn.connected) return error.NotConnected;
        if (mode_idx >= conn.modes.len) return error.InvalidMode;
        const mode = conn.modes[mode_idx];
        if (mode.hdisplay == 0 or mode.vdisplay == 0) return error.InvalidMode;

        const crtc = try self.findCrtc(conn);

        // Constraint #12: never free buffers under a pending flip.
        if (self.flip_pending) try self.waitFlip();

        self.destroyBuffers();
        self.createBuffers(mode.hdisplay, mode.vdisplay) catch |err| {
            self.destroyBuffers();
            return err;
        };

        // Full modeset: fb + mode validated against each other, count must
        // match the connector array (recipes §3 constraints 1-2).
        self.ops.set_crtc(self.ops.ctx, self.fd, crtc.id, self.bufs[0].fb_id, 0, 0, &.{conn.id}, &mode) catch |err| {
            self.destroyBuffers();
            return err;
        };

        self.active = .{
            .connector_id = conn.id,
            .mode_idx = mode_idx,
            .crtc_id = crtc.id,
            .crtc_index = crtc.index,
            .mode = mode,
        };
        self.front = 0;
        self.flip_pending = false;
        self.full_redraw = true;
        self.infos[connector_idx].current_mode = mode_idx;

        // Probe DirtyFB once per modeset with both-absent clips (recipes §6
        // policy 1). ENOSYS/EOPNOTSUPP is the common dumb-buffer case.
        self.dirtyfb_supported = true;
        self.ops.dirty_fb(self.ops.ctx, self.fd, self.bufs[0].fb_id, &.{}) catch {
            self.dirtyfb_supported = false;
        };

        if (self.dpms != .on) try self.applyDpms(self.dpms);
    }

    /// kmscon modeset_find_crtc (recipes §2.3): bound encoder first, then
    /// walk possible encoders against the CRTC list by *index* bit.
    fn findCrtc(self: *Drm2d, conn: *const Conn) !Crtc {
        if (conn.encoder_id != 0) {
            if (self.ops.get_encoder(self.ops.ctx, self.fd, conn.encoder_id)) |enc| {
                if (enc.crtc_id != 0) {
                    for (self.resources.crtcs, 0..) |cid, j| {
                        if (cid == enc.crtc_id) return .{ .id = cid, .index = j };
                    }
                }
            } else |_| {}
        }
        for (conn.encoders) |eid| {
            const enc = self.ops.get_encoder(self.ops.ctx, self.fd, eid) catch continue;
            for (self.resources.crtcs, 0..) |cid, j| {
                if (j >= 32) break;
                if (enc.possible_crtcs & (@as(u32, 1) << @intCast(j)) != 0) {
                    return .{ .id = cid, .index = j };
                }
            }
        }
        return error.NoCrtcAvailable;
    }

    // ------------------------------------------------------------------
    // Frame loop
    // ------------------------------------------------------------------

    /// The back buffer to draw into. error.Busy while a flip is in flight:
    /// with two buffers the back buffer belongs to the pending flip and must
    /// not be written until FLIP_COMPLETE (recipes §5.5).
    pub fn beginFrame(self: *Drm2d) !*Framebuffer {
        if (!self.bufs_live) return error.NoActiveDisplay;
        if (self.flip_pending) return error.Busy;
        return &self.bufs[self.front ^ 1].view;
    }

    /// Submit a page flip presenting the back buffer (returns once
    /// SUBMITTED, contract). Damage is an advisory DirtyFB hint sent between
    /// render and flip; empty damage presents everything. Refuses while a
    /// flip is pending or DPMS is not on (recipes §7.2.3). EBUSY keeps the
    /// pending flag set — never clear it on EBUSY (constraint #4).
    pub fn endFrame(self: *Drm2d, damage: []const Damage) !void {
        const act = self.active orelse return error.NoActiveDisplay;
        if (self.flip_pending) return error.Busy;
        if (self.dpms != .on) return error.DisplayOff;
        const back = self.front ^ 1;
        const buf = &self.bufs[back];

        // Constraint #10: no damage on the first frame after a modeset, and
        // clips always describe the fb being flipped, half-open, <= 256.
        if (self.dirtyfb_supported and !self.full_redraw and damage.len > 0) {
            var clips: [drm.FB_DIRTY_MAX_CLIPS]Clip = undefined;
            var n: usize = 0;
            for (damage) |d| {
                const c = d.clipTo(act.mode.hdisplay, act.mode.vdisplay) orelse continue;
                if (n == clips.len) break;
                clips[n] = .{
                    .x1 = @intCast(c.x),
                    .y1 = @intCast(c.y),
                    .x2 = @intCast(c.x + c.w),
                    .y2 = @intCast(c.y + c.h),
                };
                n += 1;
            }
            if (n > 0) {
                self.ops.dirty_fb(self.ops.ctx, self.fd, buf.fb_id, clips[0..n]) catch |err| switch (err) {
                    // Constraint #11: ENOSYS/EOPNOTSUPP is normal (bochs).
                    error.Unsupported => self.dirtyfb_supported = false,
                    else => return err,
                };
            }
        }

        self.ops.page_flip(self.ops.ctx, self.fd, act.crtc_id, buf.fb_id, drm.PAGE_FLIP_EVENT, flip_cookie) catch |err| switch (err) {
            error.Busy => {
                // A flip from an earlier submit is still in flight: keep
                // pending set, drop this frame, retry after FLIP_COMPLETE.
                self.flip_pending = true;
                self.flipping_to = back;
                return error.Busy;
            },
            else => return err,
        };
        self.flip_pending = true;
        self.flipping_to = back;
        self.full_redraw = false;
    }

    /// True while a submitted flip has not completed. Pure flag: the loop
    /// drives completion by calling readEvents when eventFd is readable.
    pub fn flipPending(self: *const Drm2d) bool {
        return self.flip_pending;
    }

    /// Block until the pending flip completes, bounded at 1000 ms like
    /// kmscon's drm_video_wait_pflip (recipes §5.4). error.Timeout when the
    /// event never arrives; the pending flag stays set.
    pub fn waitFlip(self: *Drm2d) !void {
        if (!self.flip_pending) return;
        var waited_ms: i32 = 0;
        while (self.flip_pending) {
            try self.readEvents();
            if (!self.flip_pending) return;
            if (waited_ms >= 1000) return error.Timeout;
            try self.ops.poll(self.ops.ctx, self.fd, 100);
            waited_ms += 100;
        }
    }

    /// Drain the DRM event fd (call from the loop on readability, or from
    /// waitFlip). Parses drm_event_vblank manually: 32 bytes, user_data @8,
    /// crtc_id @28 (recipes §5.2, verified layout §0.2). FLIP_COMPLETE for
    /// our CRTC (or crtc_id 0 on old kernels) with our cookie clears the
    /// pending flag and swaps front/back. error.WouldBlock means drained.
    pub fn readEvents(self: *Drm2d) !void {
        var buf: [1024]u8 align(8) = undefined;
        while (true) {
            const n = self.ops.read(self.ops.ctx, self.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (n == 0) return;
            try self.parseEvents(buf[0..n]);
            if (n < buf.len) return;
        }
    }

    fn parseEvents(self: *Drm2d, bytes: []const u8) !void {
        var off: usize = 0;
        while (off + 8 <= bytes.len) {
            const typ = std.mem.readInt(u32, bytes[off..][0..4], .little);
            const len = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
            if (len < 8 or off + len > bytes.len) return error.MalformedEvent;
            if (typ == drm.EVENT_FLIP_COMPLETE and len >= 32) {
                const user_data = std.mem.readInt(u64, bytes[off + 8 ..][0..8], .little);
                const crtc_id = std.mem.readInt(u32, bytes[off + 28 ..][0..4], .little);
                if (user_data == flip_cookie and self.flip_pending) {
                    if (self.active) |act| {
                        // crtc_id 0: kernel without DRM_CAP_CRTC_IN_VBLANK_EVENT.
                        if (crtc_id == 0 or crtc_id == act.crtc_id) {
                            self.flip_pending = false;
                            self.front = self.flipping_to;
                        }
                    }
                }
            }
            off += len;
        }
    }

    /// True when the next endFrame must present everything (first frame
    /// after a modeset or DPMS-on wake). The renderer should redraw fully.
    pub fn needsFullRedraw(self: *const Drm2d) bool {
        return self.full_redraw;
    }

    // ------------------------------------------------------------------
    // DPMS
    // ------------------------------------------------------------------

    /// Set the DPMS state on the active connector through its legacy "DPMS"
    /// property (recipes §7). Waking to .on re-runs SetCrtc before any flip
    /// (constraint #5, recipes §7.2.3). error.Unsupported when the connector
    /// has no DPMS property; error.NoActiveDisplay before the first setMode.
    pub fn setDpms(self: *Drm2d, state: DpmsState) !void {
        const act = self.active orelse return error.NoActiveDisplay;
        const was = self.dpms;
        try self.applyDpms(state);
        self.dpms = state;
        if (state == .on and was != .on) {
            if (self.flip_pending) try self.waitFlip();
            try self.ops.set_crtc(self.ops.ctx, self.fd, act.crtc_id, self.bufs[self.front].fb_id, 0, 0, &.{act.connector_id}, &act.mode);
            self.full_redraw = true;
        }
    }

    fn applyDpms(self: *Drm2d, state: DpmsState) !void {
        const act = self.active orelse return error.NoActiveDisplay;
        const idx = self.connIndex(act.connector_id) orelse return error.NoActiveDisplay;
        const prop_id = self.conns[idx].dpms_prop_id orelse return error.Unsupported;
        try self.ops.connector_set_property(self.ops.ctx, self.fd, act.connector_id, prop_id, dpmsValue(state));
    }

    pub fn dpmsState(self: *const Drm2d) DpmsState {
        return self.dpms;
    }

    // ------------------------------------------------------------------
    // Hardware cursor (legacy SetCursor2 path, recipes §8.1/§8.3/§8.4)
    // ------------------------------------------------------------------

    /// Position a hardware cursor image at (x, y), or hide it when img is
    /// null. The image is copied (top-left overlap, no scaling) into an
    /// ARGB8888 dumb buffer sized from DRM_CAP_CURSOR_WIDTH/HEIGHT. Any
    /// device failure permanently disables the hardware cursor and returns
    /// error.Unsupported so the renderer composites a software cursor.
    pub fn setCursor(self: *Drm2d, img: ?*Framebuffer, x: i32, y: i32) !void {
        const act = self.active orelse return error.NoActiveDisplay;
        if (!self.supportsHwCursor()) return error.Unsupported;

        if (img == null) {
            // handle 0 turns the cursor off (recipes §8.1).
            self.ops.set_cursor2(self.ops.ctx, self.fd, act.crtc_id, 0, 0, 0, 0, 0) catch return self.cursorFallback();
            return;
        }
        const image = img.?;
        const w = self.cursor_w.?;
        const h = self.cursor_h.?;

        if (self.cursor_buf == null) {
            self.cursor_buf = self.createCursorBuffer(w, h) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return self.cursorFallback(),
            };
        }
        const cb = &self.cursor_buf.?;

        // Zero first so pixels outside the copied region are transparent.
        @memset(cb.map, 0);
        const copy_w = @min(image.width, w);
        const copy_h = @min(image.height, h);
        var row: u32 = 0;
        while (row < copy_h) : (row += 1) {
            const src = image.mem[@as(usize, row) * image.pitch ..][0 .. @as(usize, copy_w) * 4];
            const dst = cb.map[@as(usize, row) * cb.pitch ..][0 .. @as(usize, copy_w) * 4];
            if (image.format == .argb8888) {
                @memcpy(dst, src);
            } else {
                // XRGB source: force opaque alpha.
                var i: usize = 0;
                while (i < copy_w) : (i += 1) {
                    const px = std.mem.readInt(u32, src[i * 4 ..][0..4], .little) | 0xFF00_0000;
                    std.mem.writeInt(u32, dst[i * 4 ..][0..4], px, .little);
                }
            }
        }

        // Hotspot (0,0): the hotspot cap is not set on the legacy path
        // (recipes §8.1).
        self.ops.set_cursor2(self.ops.ctx, self.fd, act.crtc_id, cb.handle, w, h, 0, 0) catch return self.cursorFallback();
        self.ops.move_cursor(self.ops.ctx, self.fd, act.crtc_id, x, y) catch return self.cursorFallback();
    }

    /// Whether setCursor can use a hardware cursor plane (M5.7). True only
    /// when a cursor plane exists for the active CRTC, the size caps are
    /// present, no SetCursor2 attempt has failed, and `--soft-cursor` is not
    /// forcing software (constraint #8: caps alone do not prove a plane).
    pub fn supportsHwCursor(self: *const Drm2d) bool {
        if (self.force_soft_cursor or self.hw_cursor_failed) return false;
        if (self.cursor_w == null or self.cursor_h == null) return false;
        if (self.cursor_planes.len == 0) return false;
        if (self.active) |act| return self.cursorPlaneForCrtc(act.crtc_index) != null;
        return true; // a plane exists; no CRTC chosen yet
    }

    /// The cursor plane id that can drive CRTC index `crtc_index`, or null.
    fn cursorPlaneForCrtc(self: *const Drm2d, crtc_index: usize) ?u32 {
        if (crtc_index >= 32) return null;
        const bit = @as(u32, 1) << @intCast(crtc_index);
        for (self.cursor_planes) |p| {
            if (p.possible_crtcs & bit != 0) return p.id;
        }
        return null;
    }

    /// Force the software cursor (`--soft-cursor`, M5.7). Hides any active
    /// hardware cursor first; afterwards supportsHwCursor() is false and
    /// setCursor() returns error.Unsupported so the renderer composites it.
    pub fn setSoftCursorForce(self: *Drm2d, force: bool) void {
        if (force and !self.force_soft_cursor and self.supportsHwCursor()) {
            if (self.active) |act| {
                self.ops.set_cursor2(self.ops.ctx, self.fd, act.crtc_id, 0, 0, 0, 0, 0) catch {};
            }
        }
        self.force_soft_cursor = force;
    }

    /// Choose a mode index for connector `connector_idx` (M5.3): a matching
    /// `mode=` spec wins, else use-original-mode keeps the current mode,
    /// else preferred, else mode 0 (layout.selectMode). `spec` is the
    /// resolved ModeSpec for this connector (layout.lookupMode), null when
    /// none matches. Null result when the connector has no modes.
    pub fn selectModeIndex(self: *const Drm2d, connector_idx: usize, spec: ?video.ModeSpec, use_original: bool) !?usize {
        if (connector_idx >= self.conns.len) return null;
        const conn = &self.conns[connector_idx];
        if (conn.info_modes.len == 0) return null;
        const candidates = try self.allocator.alloc(video.layout.ModeCandidate, conn.info_modes.len);
        defer self.allocator.free(candidates);
        for (conn.info_modes, 0..) |m, i| {
            candidates[i] = .{
                .width = m.width_px,
                .height = m.height_px,
                .refresh_hz = (m.refresh_mhz + 500) / 1000,
            };
        }
        var preferred: ?usize = null;
        for (conn.modes, 0..) |m, j| {
            if (m.isPreferred()) {
                preferred = j;
                break;
            }
        }
        if (preferred == null) preferred = 0;
        return video.layout.selectMode(candidates, spec, use_original, preferred, conn.current_mode);
    }

    /// Enable the hotplug event source (M5.5). The loop polls hotplugFd()
    /// and, on readability, calls pollHotplug() then connectors() to
    /// re-probe (recipes §9.2: hotplug is a re-enumeration trigger, not a
    /// reopen). Idempotent.
    pub fn enableHotplug(self: *Drm2d, ops: HotplugOps) !void {
        if (self.hotplug != null) return;
        self.hotplug = try Hotplug.init(ops);
    }

    /// The hotplug monitor fd for the epoll loop, or null when not enabled.
    pub fn hotplugFd(self: *const Drm2d) ?i32 {
        if (self.hotplug) |*h| return h.fd();
        return null;
    }

    /// Drain pending hotplug events; true when at least one arrived. The
    /// caller then re-probes via connectors(). False when hotplug is off.
    pub fn pollHotplug(self: *Drm2d) !bool {
        if (self.hotplug) |*h| return h.poll();
        return false;
    }

    fn cursorFallback(self: *Drm2d) anyerror {
        self.hw_cursor_failed = true;
        self.cursorTeardown();
        return error.Unsupported;
    }

    fn createCursorBuffer(self: *Drm2d, w: u32, h: u32) !CursorBuffer {
        const db = try self.ops.create_dumb(self.ops.ctx, self.fd, w, h, 32);
        errdefer self.ops.destroy_dumb(self.ops.ctx, self.fd, db.handle) catch {};
        // Constraint #9: the legacy/universal cursor wrap assumes tight
        // pitch; a padded dumb pitch would shear the image.
        if (db.pitch != w * 4) return error.Unsupported;
        const offset = try self.ops.map_dumb(self.ops.ctx, self.fd, db.handle);
        const map = try self.ops.mmap(self.ops.ctx, self.fd, @intCast(db.size), offset);
        return .{
            .handle = db.handle,
            .size = db.size,
            .width = w,
            .height = h,
            .pitch = db.pitch,
            .map = map,
        };
    }

    fn cursorTeardown(self: *Drm2d) void {
        if (self.cursor_buf) |*cb| {
            self.ops.munmap(self.ops.ctx, cb.map);
            self.ops.destroy_dumb(self.ops.ctx, self.fd, cb.handle) catch {};
            self.cursor_buf = null;
        }
    }

    // ------------------------------------------------------------------
    // Buffers
    // ------------------------------------------------------------------

    /// kmscon init_rb order: create -> addfb -> map_dumb -> mmap -> memset
    /// (recipes §4.2); depth 24 / bpp 32 maps to XRGB8888 (recipes §4.3),
    /// the same fourcc on both buffers so flips never change format
    /// (constraint #6).
    fn createBuffer(self: *Drm2d, w: u32, h: u32) !Buffer {
        const db = try self.ops.create_dumb(self.ops.ctx, self.fd, w, h, 32);
        errdefer self.ops.destroy_dumb(self.ops.ctx, self.fd, db.handle) catch {};
        const fb_id = try self.ops.add_fb(self.ops.ctx, self.fd, w, h, 24, 32, db.pitch, db.handle);
        errdefer self.ops.rm_fb(self.ops.ctx, self.fd, fb_id) catch {};
        const offset = try self.ops.map_dumb(self.ops.ctx, self.fd, db.handle);
        const map = try self.ops.mmap(self.ops.ctx, self.fd, @intCast(db.size), offset);
        @memset(map, 0);
        const len = @as(usize, db.pitch) * h;
        return .{
            .handle = db.handle,
            .fb_id = fb_id,
            .size = db.size,
            .map = map,
            .view = .{
                .mem = @alignCast(map[0..len]),
                .width = w,
                .height = h,
                .pitch = db.pitch,
                .format = .xrgb8888,
            },
        };
    }

    fn createBuffers(self: *Drm2d, w: u32, h: u32) !void {
        var created: usize = 0;
        errdefer {
            for (self.bufs[0..created]) |*b| self.destroyBuffer(b);
            self.bufs_live = false;
        }
        for (&self.bufs) |*b| {
            b.* = try self.createBuffer(w, h);
            created += 1;
        }
        self.bufs_live = true;
    }

    /// Constraint #13: munmap -> RmFB -> DestroyDumb. Failures during
    /// teardown are logged-and-continued (recipes §4.4).
    fn destroyBuffer(self: *Drm2d, b: *Buffer) void {
        self.ops.munmap(self.ops.ctx, b.map);
        self.ops.rm_fb(self.ops.ctx, self.fd, b.fb_id) catch {};
        self.ops.destroy_dumb(self.ops.ctx, self.fd, b.handle) catch {};
        b.* = undefined;
    }

    fn destroyBuffers(self: *Drm2d) void {
        if (!self.bufs_live) return;
        for (&self.bufs) |*b| self.destroyBuffer(b);
        self.bufs_live = false;
    }

    // ------------------------------------------------------------------
    // vtable
    // ------------------------------------------------------------------

    const vtable = video.Backend.VTable{
        .deinit = vtDeinit,
        .connectors = vtConnectors,
        .setMode = vtSetMode,
        .beginFrame = vtBeginFrame,
        .endFrame = vtEndFrame,
        .flipPending = vtFlipPending,
        .waitFlip = vtWaitFlip,
        .setDpms = vtSetDpms,
        .setCursor = vtSetCursor,
        .supportsHwCursor = vtSupportsHwCursor,
    };

    fn cast(ptr: *anyopaque) *Drm2d {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }
    fn vtConnectors(ptr: *anyopaque) anyerror![]const ConnectorInfo {
        return cast(ptr).connectors();
    }
    fn vtSetMode(ptr: *anyopaque, connector_idx: usize, mode_idx: usize) anyerror!void {
        return cast(ptr).setMode(connector_idx, mode_idx);
    }
    fn vtBeginFrame(ptr: *anyopaque) anyerror!*Framebuffer {
        return cast(ptr).beginFrame();
    }
    fn vtEndFrame(ptr: *anyopaque, damage: []const Damage) anyerror!void {
        return cast(ptr).endFrame(damage);
    }
    fn vtFlipPending(ptr: *anyopaque) bool {
        return cast(ptr).flipPending();
    }
    fn vtWaitFlip(ptr: *anyopaque) anyerror!void {
        return cast(ptr).waitFlip();
    }
    fn vtSetDpms(ptr: *anyopaque, state: DpmsState) anyerror!void {
        return cast(ptr).setDpms(state);
    }
    fn vtSetCursor(ptr: *anyopaque, img: ?*Framebuffer, x: i32, y: i32) anyerror!void {
        return cast(ptr).setCursor(img, x, y);
    }
    fn vtSupportsHwCursor(ptr: *anyopaque) bool {
        return cast(ptr).supportsHwCursor();
    }
};

// ---------------------------------------------------------------------------
// Enumeration helpers (shared by init and connectors)
// ---------------------------------------------------------------------------

fn capOptional(ops: DrmOps, fd: i32, cap: u64) ?u32 {
    var value: u64 = 0;
    ops.get_cap(ops.ctx, fd, cap, &value) catch return null;
    if (value == 0 or value > std.math.maxInt(u32)) return null;
    return @intCast(value);
}

fn enumerateConnectors(allocator: Allocator, ops: DrmOps, fd: i32, res: *const Resources, force_probe: bool) ![]Conn {
    var list: std.ArrayList(Conn) = .empty;
    errdefer {
        for (list.items) |*c| c.deinit(allocator);
        list.deinit(allocator);
    }
    for (res.connectors) |cid| {
        var snap = ops.get_connector(ops.ctx, fd, allocator, cid, force_probe) catch continue;
        defer snap.deinit(allocator);
        try list.append(allocator, try connFromSnapshot(allocator, ops, fd, &snap));
    }
    return list.toOwnedSlice(allocator);
}

fn connFromSnapshot(allocator: Allocator, ops: DrmOps, fd: i32, snap: *const Connector) !Conn {
    const type_name = connectorTypeName(snap.connector_type) orelse "Unknown";
    const name = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ type_name, snap.connector_type_id });
    errdefer allocator.free(name);

    const modes = try allocator.dupe(ModeInfo, snap.modes);
    errdefer allocator.free(modes);

    const info_modes = try allocator.alloc(Mode, modes.len);
    errdefer allocator.free(info_modes);
    for (modes, 0..) |m, i| info_modes[i] = toVideoMode(m, snap.mm_width, snap.mm_height);

    const encoders = try allocator.dupe(u32, snap.encoders);
    errdefer allocator.free(encoders);

    // DPMS property discovery, exactly as kmscon drm_set_dpms (recipes
    // §7.1): walk the connector's props, match the name "DPMS".
    var dpms_prop_id: ?u32 = null;
    if (snap.connection == .connected) {
        for (snap.props) |p| {
            const prop = ops.get_property(ops.ctx, fd, p.id) catch continue;
            if (std.mem.eql(u8, prop.nameSlice(), "DPMS")) {
                dpms_prop_id = prop.prop_id;
                break;
            }
        }
    }

    // Current mode (use-original-mode, recipes §2.4): follow the bound
    // encoder to its CRTC and match the CRTC's live mode against the
    // connector's mode list by resolution + pixel clock. Skipped when the
    // seam lacks get_crtc (current_mode stays null).
    var current_mode: ?usize = null;
    if (snap.connection == .connected and snap.encoder_id != 0) {
        if (ops.get_crtc) |get_crtc| {
            if (ops.get_encoder(ops.ctx, fd, snap.encoder_id)) |enc| {
                if (enc.crtc_id != 0) {
                    if (get_crtc(ops.ctx, fd, enc.crtc_id)) |crtc| {
                        if (crtc.mode_valid) {
                            for (modes, 0..) |m, i| {
                                if (m.hdisplay == crtc.mode.hdisplay and
                                    m.vdisplay == crtc.mode.vdisplay and
                                    m.clock == crtc.mode.clock)
                                {
                                    current_mode = i;
                                    break;
                                }
                            }
                        }
                    } else |_| {}
                }
            } else |_| {}
        }
    }

    return .{
        .id = snap.connector_id,
        .connector_type = snap.connector_type,
        .type_id = snap.connector_type_id,
        .connected = snap.connection == .connected,
        .mm_width = snap.mm_width,
        .mm_height = snap.mm_height,
        .encoder_id = snap.encoder_id,
        .encoders = encoders,
        .modes = modes,
        .info_modes = info_modes,
        .name = name,
        .dpms_prop_id = dpms_prop_id,
        .current_mode = current_mode,
    };
}

fn buildInfos(allocator: Allocator, conns: []const Conn, card_path: []const u8) ![]ConnectorInfo {
    const infos = try allocator.alloc(ConnectorInfo, conns.len);
    errdefer allocator.free(infos);
    const card_name = std.fs.path.basename(card_path);
    for (conns, 0..) |c, i| {
        var preferred: ?usize = null;
        for (c.modes, 0..) |m, j| {
            if (m.isPreferred()) {
                preferred = j;
                break;
            }
        }
        // Preferred mode rule: first DRM_MODE_TYPE_PREFERRED, else modes[0]
        // (kmscon init_modes, recipes §2.2).
        if (preferred == null and c.modes.len > 0) preferred = 0;
        infos[i] = .{
            .name = c.name,
            .card_name = card_name,
            .connected = c.connected,
            .modes = c.info_modes,
            .preferred_mode = preferred,
            .current_mode = c.current_mode,
        };
    }
    return infos;
}

/// Discover cursor planes via universal planes (recipes §8.2, constraint
/// #8). UNIVERSAL_PLANES must already be set. Returns an allocator-owned
/// slice (possibly empty): empty when the seam lacks the plane ops, the
/// driver lists no planes, or no plane has type CURSOR. A 64x64 cap answer
/// alone never reaches here — only a real plane makes supportsHwCursor true.
fn detectCursorPlanes(allocator: Allocator, ops: DrmOps, fd: i32) ![]CursorPlane {
    var list: std.ArrayList(CursorPlane) = .empty;
    errdefer list.deinit(allocator);
    const get_res = ops.get_plane_resources orelse return list.toOwnedSlice(allocator);
    const get_plane = ops.get_plane orelse return list.toOwnedSlice(allocator);
    const get_props = ops.object_get_properties orelse return list.toOwnedSlice(allocator);

    var res = get_res(ops.ctx, fd, allocator) catch return list.toOwnedSlice(allocator);
    defer res.deinit(allocator);
    for (res.planes) |pid| {
        const plane = get_plane(ops.ctx, fd, pid) catch continue;
        var props = get_props(ops.ctx, fd, allocator, pid, drm.OBJECT_PLANE) catch continue;
        defer props.deinit(allocator);
        var is_cursor = false;
        for (props.props) |pv| {
            const prop = ops.get_property(ops.ctx, fd, pv.id) catch continue;
            if (std.mem.eql(u8, prop.nameSlice(), "type") and pv.value == drm.PLANE_TYPE_CURSOR) {
                is_cursor = true;
                break;
            }
        }
        if (is_cursor) try list.append(allocator, .{ .id = pid, .possible_crtcs = plane.possible_crtcs });
    }
    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Hotplug event source (ROADMAP M5.5, recipes §9).
//
// connectors() already re-probes; this is the pollable trigger that tells the
// loop WHEN to re-probe. A udev monitor on the "drm" subsystem yields add /
// remove / change events; change is filtered to HOTPLUG=1 (recipes §9.1/§9.2).
// The seam keeps it hermetic: production is libudev.hotplugOps(), tests inject
// a fake event queue.
// ---------------------------------------------------------------------------

/// A relevant udev action on a DRM minor (recipes §9.2).
pub const HotplugEvent = enum { add, remove, change };

/// udev monitor seam. `open` creates a monitor filtered to subsystem "drm";
/// `next` yields one relevant event (change already filtered to HOTPLUG=1)
/// or null when drained; `fd` is the pollable netlink fd.
pub const HotplugOps = struct {
    ctx: ?*anyopaque = null,
    open: *const fn (ctx: ?*anyopaque) anyerror!*anyopaque,
    close: *const fn (ctx: ?*anyopaque, handle: *anyopaque) void,
    fd: *const fn (ctx: ?*anyopaque, handle: *anyopaque) i32,
    next: *const fn (ctx: ?*anyopaque, handle: *anyopaque) anyerror!?HotplugEvent,
};

/// Owns a hotplug monitor handle behind HotplugOps.
pub const Hotplug = struct {
    ops: HotplugOps,
    handle: *anyopaque,

    pub fn init(ops: HotplugOps) !Hotplug {
        return .{ .ops = ops, .handle = try ops.open(ops.ctx) };
    }

    pub fn deinit(self: *Hotplug) void {
        self.ops.close(self.ops.ctx, self.handle);
    }

    pub fn fd(self: *const Hotplug) i32 {
        return self.ops.fd(self.ops.ctx, self.handle);
    }

    /// Drain pending events; true when at least one relevant event arrived.
    pub fn poll(self: *Hotplug) !bool {
        var any = false;
        while (try self.ops.next(self.ops.ctx, self.handle)) |_| {
            any = true;
        }
        return any;
    }
};

// ---------------------------------------------------------------------------
// Real libdrm implementation.
//
// The `drm-c` import lives inside this namespace so the hermetic test build
// never resolves it. Referenced only through libdrm.ops() (production) or
// the link_libc-gated test below (real-wrapper verification).
// ---------------------------------------------------------------------------

pub const libdrm = struct {
    const c = @import("drm-c");

    comptime {
        // The seam copies modes/clips by layout; prove the layouts agree
        // with the pinned translate-c output (recipes §0.2).
        std.debug.assert(@sizeOf(ModeInfo) == @sizeOf(c.drmModeModeInfo));
        std.debug.assert(@sizeOf(Clip) == @sizeOf(c.drm_clip_rect));
    }

    /// DrmOps backed by the system libdrm.
    pub fn ops() DrmOps {
        return .{
            .open = open,
            .close = close,
            .set_master = setMaster,
            .drop_master = dropMaster,
            .is_master = isMaster,
            .get_cap = getCap,
            .set_client_cap = setClientCap,
            .get_resources = getResources,
            .get_connector = getConnector,
            .get_encoder = getEncoder,
            .get_property = getProperty,
            .set_crtc = setCrtc,
            .create_dumb = createDumb,
            .map_dumb = mapDumb,
            .destroy_dumb = destroyDumb,
            .add_fb = addFb,
            .rm_fb = rmFb,
            .dirty_fb = dirtyFb,
            .page_flip = pageFlip,
            .connector_set_property = connectorSetProperty,
            .set_cursor2 = setCursor2,
            .move_cursor = moveCursor,
            .get_crtc = getCrtc,
            .get_plane_resources = getPlaneResources,
            .get_plane = getPlane,
            .object_get_properties = objectGetProperties,
            .mmap = mmap,
            .munmap = munmap,
            .read = read,
            .poll = poll,
        };
    }

    /// KMS family: negative errno return (xf86drmMode.c:65-69, recipes §0.1).
    fn kmsError(rc: c_int) !void {
        if (rc >= 0) return;
        const e: u32 = @intCast(-rc);
        return switch (e) {
            @intFromEnum(posix.E.ACCES) => error.AccessDenied,
            @intFromEnum(posix.E.BUSY) => error.Busy,
            @intFromEnum(posix.E.NOENT) => error.NotFound,
            @intFromEnum(posix.E.NOSYS), @intFromEnum(posix.E.OPNOTSUPP) => error.Unsupported,
            @intFromEnum(posix.E.INVAL) => error.InvalidArgument,
            @intFromEnum(posix.E.NOMEM) => error.OutOfMemory,
            @intFromEnum(posix.E.AGAIN) => error.WouldBlock,
            else => error.DrmCallFailed,
        };
    }

    /// Core family: -1 with errno set (xf86drm.c, recipes §0.1).
    fn coreError() anyerror {
        const e: u32 = @intCast(std.c._errno().*);
        return switch (e) {
            @intFromEnum(posix.E.ACCES) => error.AccessDenied,
            @intFromEnum(posix.E.BUSY) => error.Busy,
            @intFromEnum(posix.E.NOENT) => error.NotFound,
            @intFromEnum(posix.E.NOSYS), @intFromEnum(posix.E.OPNOTSUPP) => error.Unsupported,
            @intFromEnum(posix.E.INVAL) => error.InvalidArgument,
            @intFromEnum(posix.E.NOMEM) => error.OutOfMemory,
            else => error.DrmCallFailed,
        };
    }

    fn open(_: ?*anyopaque, path: [*:0]const u8) !i32 {
        return posix.openat(posix.AT.FDCWD, std.mem.span(path), .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NONBLOCK = true }, 0);
    }

    fn close(_: ?*anyopaque, fd: i32) void {
        // close() releases the fd even on error; nothing to retry (same
        // convention as loop.zig closeFd).
        _ = std.os.linux.close(fd);
    }

    fn setMaster(_: ?*anyopaque, fd: i32) !void {
        if (c.drmSetMaster(fd) < 0) return coreError();
    }

    fn dropMaster(_: ?*anyopaque, fd: i32) !void {
        if (c.drmDropMaster(fd) < 0) return coreError();
    }

    fn isMaster(_: ?*anyopaque, fd: i32) !bool {
        return c.drmIsMaster(fd) == 1;
    }

    fn getCap(_: ?*anyopaque, fd: i32, cap: u64, value: *u64) !void {
        if (c.drmGetCap(fd, cap, value) < 0) return coreError();
    }

    fn setClientCap(_: ?*anyopaque, fd: i32, cap: u64, value: u64) !void {
        if (c.drmSetClientCap(fd, cap, value) < 0) return coreError();
    }

    fn getResources(_: ?*anyopaque, fd: i32, allocator: Allocator) !Resources {
        const r: *c.struct__drmModeRes = @ptrCast(c.drmModeGetResources(fd) orelse return coreError());
        defer c.drmModeFreeResources(r);
        const crtcs = try allocator.dupe(u32, r.crtcs[0..@intCast(r.count_crtcs)]);
        errdefer allocator.free(crtcs);
        const connectors = try allocator.dupe(u32, r.connectors[0..@intCast(r.count_connectors)]);
        errdefer allocator.free(connectors);
        const encoders = try allocator.dupe(u32, r.encoders[0..@intCast(r.count_encoders)]);
        return .{
            .crtcs = crtcs,
            .connectors = connectors,
            .encoders = encoders,
            .min_width = r.min_width,
            .max_width = r.max_width,
            .min_height = r.min_height,
            .max_height = r.max_height,
        };
    }

    fn getConnector(_: ?*anyopaque, fd: i32, allocator: Allocator, connector_id: u32, force_probe: bool) !Connector {
        // libdrm performs the two-phase count/fill ioctl dance internally
        // (xf86drmMode.c:508-560, recipes §2.2).
        const conn: *c.struct__drmModeConnector = @ptrCast((if (force_probe)
            c.drmModeGetConnector(fd, connector_id)
        else
            c.drmModeGetConnectorCurrent(fd, connector_id)) orelse return coreError());
        defer c.drmModeFreeConnector(conn);

        const count_modes: usize = @intCast(conn.count_modes);
        const modes = try allocator.dupe(ModeInfo, if (count_modes > 0)
            @as([*]const ModeInfo, @ptrCast(conn.modes))[0..count_modes]
        else
            &[_]ModeInfo{});
        errdefer allocator.free(modes);

        const count_props: usize = @intCast(conn.count_props);
        const props = try allocator.alloc(PropValue, count_props);
        errdefer allocator.free(props);
        for (0..count_props) |i| props[i] = .{ .id = conn.props[i], .value = conn.prop_values[i] };

        const encoders = try allocator.dupe(u32, conn.encoders[0..@intCast(conn.count_encoders)]);
        errdefer allocator.free(encoders);

        return .{
            .connector_id = conn.connector_id,
            .encoder_id = conn.encoder_id,
            .connector_type = conn.connector_type,
            .connector_type_id = conn.connector_type_id,
            .connection = @enumFromInt(conn.connection),
            .mm_width = conn.mmWidth,
            .mm_height = conn.mmHeight,
            .modes = modes,
            .props = props,
            .encoders = encoders,
        };
    }

    fn getEncoder(_: ?*anyopaque, fd: i32, encoder_id: u32) !Encoder {
        const e: *c.struct__drmModeEncoder = @ptrCast(c.drmModeGetEncoder(fd, encoder_id) orelse return coreError());
        defer c.drmModeFreeEncoder(e);
        return .{
            .encoder_id = e.encoder_id,
            .encoder_type = e.encoder_type,
            .crtc_id = e.crtc_id,
            .possible_crtcs = e.possible_crtcs,
            .possible_clones = e.possible_clones,
        };
    }

    fn getProperty(_: ?*anyopaque, fd: i32, prop_id: u32) !Property {
        const p: *c.struct__drmModeProperty = @ptrCast(c.drmModeGetProperty(fd, prop_id) orelse return coreError());
        defer c.drmModeFreeProperty(p);
        return .{ .prop_id = p.prop_id, .flags = p.flags, .name = p.name };
    }

    fn setCrtc(_: ?*anyopaque, fd: i32, crtc_id: u32, fb_id: u32, x: u32, y: u32, connector_ids: []const u32, mode: ?*const ModeInfo) !void {
        // Layout identity with ModeInfo is asserted at comptime above.
        const mode_ptr: ?*c.drmModeModeInfo = if (mode) |m| @ptrCast(@constCast(m)) else null;
        const rc = c.drmModeSetCrtc(
            fd,
            crtc_id,
            fb_id,
            x,
            y,
            @constCast(connector_ids.ptr),
            @intCast(connector_ids.len),
            mode_ptr,
        );
        try kmsError(rc);
    }

    fn createDumb(_: ?*anyopaque, fd: i32, width: u32, height: u32, bpp: u32) !DumbBuffer {
        var handle: u32 = 0;
        var pitch: u32 = 0;
        var size: u64 = 0;
        try kmsError(c.drmModeCreateDumbBuffer(fd, width, height, bpp, 0, &handle, &pitch, &size));
        return .{ .handle = handle, .pitch = pitch, .size = size };
    }

    fn mapDumb(_: ?*anyopaque, fd: i32, handle: u32) !u64 {
        var offset: u64 = 0;
        try kmsError(c.drmModeMapDumbBuffer(fd, handle, &offset));
        return offset;
    }

    fn destroyDumb(_: ?*anyopaque, fd: i32, handle: u32) !void {
        try kmsError(c.drmModeDestroyDumbBuffer(fd, handle));
    }

    fn addFb(_: ?*anyopaque, fd: i32, width: u32, height: u32, depth: u8, bpp: u8, pitch: u32, handle: u32) !u32 {
        var buf_id: u32 = 0;
        try kmsError(c.drmModeAddFB(fd, width, height, depth, bpp, pitch, handle, &buf_id));
        return buf_id;
    }

    fn rmFb(_: ?*anyopaque, fd: i32, fb_id: u32) !void {
        try kmsError(c.drmModeRmFB(fd, fb_id));
    }

    fn dirtyFb(_: ?*anyopaque, fd: i32, fb_id: u32, clips: []const Clip) !void {
        const ptr: ?*c.drm_clip_rect = if (clips.len > 0) @ptrCast(@constCast(clips.ptr)) else null;
        try kmsError(c.drmModeDirtyFB(fd, fb_id, ptr, @intCast(clips.len)));
    }

    fn pageFlip(_: ?*anyopaque, fd: i32, crtc_id: u32, fb_id: u32, flags: u32, user_data: u64) !void {
        try kmsError(c.drmModePageFlip(fd, crtc_id, fb_id, flags, @ptrFromInt(user_data)));
    }

    fn connectorSetProperty(_: ?*anyopaque, fd: i32, connector_id: u32, prop_id: u32, value: u64) !void {
        try kmsError(c.drmModeConnectorSetProperty(fd, connector_id, prop_id, value));
    }

    fn setCursor2(_: ?*anyopaque, fd: i32, crtc_id: u32, handle: u32, width: u32, height: u32, hot_x: i32, hot_y: i32) !void {
        try kmsError(c.drmModeSetCursor2(fd, crtc_id, handle, width, height, hot_x, hot_y));
    }

    fn moveCursor(_: ?*anyopaque, fd: i32, crtc_id: u32, x: i32, y: i32) !void {
        try kmsError(c.drmModeMoveCursor(fd, crtc_id, x, y));
    }

    fn getCrtc(_: ?*anyopaque, fd: i32, crtc_id: u32) !CrtcState {
        const cr: *c.struct__drmModeCrtc = @ptrCast(c.drmModeGetCrtc(fd, crtc_id) orelse return coreError());
        defer c.drmModeFreeCrtc(cr);
        return .{
            .crtc_id = cr.crtc_id,
            .buffer_id = cr.buffer_id,
            .width = cr.width,
            .height = cr.height,
            .mode_valid = cr.mode_valid != 0,
            .mode = @as(*const ModeInfo, @ptrCast(&cr.mode)).*,
        };
    }

    fn getPlaneResources(_: ?*anyopaque, fd: i32, allocator: Allocator) !PlaneResources {
        const r: *c.struct__drmModePlaneRes = @ptrCast(c.drmModeGetPlaneResources(fd) orelse return coreError());
        defer c.drmModeFreePlaneResources(r);
        const planes = try allocator.dupe(u32, r.planes[0..@intCast(r.count_planes)]);
        return .{ .planes = planes };
    }

    fn getPlane(_: ?*anyopaque, fd: i32, plane_id: u32) !Plane {
        const p: *c.struct__drmModePlane = @ptrCast(c.drmModeGetPlane(fd, plane_id) orelse return coreError());
        defer c.drmModeFreePlane(p);
        return .{
            .plane_id = p.plane_id,
            .crtc_id = p.crtc_id,
            .fb_id = p.fb_id,
            .possible_crtcs = p.possible_crtcs,
        };
    }

    fn objectGetProperties(_: ?*anyopaque, fd: i32, allocator: Allocator, object_id: u32, object_type: u32) !ObjectProperties {
        const op: *c.struct__drmModeObjectProperties = @ptrCast(c.drmModeObjectGetProperties(fd, object_id, object_type) orelse return coreError());
        defer c.drmModeFreeObjectProperties(op);
        const n: usize = @intCast(op.count_props);
        const props = try allocator.alloc(PropValue, n);
        errdefer allocator.free(props);
        for (0..n) |i| props[i] = .{ .id = op.props[i], .value = op.prop_values[i] };
        return .{ .props = props };
    }

    fn mmap(_: ?*anyopaque, fd: i32, len: usize, offset: u64) ![]align(page_align) u8 {
        // MAP_SHARED is required so the kernel sees writes without msync
        // (recipes §4.2).
        return posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, offset);
    }

    fn munmap(_: ?*anyopaque, mem: []align(page_align) u8) void {
        posix.munmap(mem);
    }

    fn read(_: ?*anyopaque, fd: i32, buf: []u8) !usize {
        return posix.read(fd, buf);
    }

    fn poll(_: ?*anyopaque, fd: i32, timeout_ms: i32) !void {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, timeout_ms);
    }

    test "ModeInfo and Clip ABI match the pinned libdrm" {
        try std.testing.expectEqual(@as(usize, 68), @sizeOf(ModeInfo));
        try std.testing.expectEqual(@as(usize, 36), @offsetOf(ModeInfo, "name"));
        try std.testing.expectEqual(@sizeOf(c.drmModeModeInfo), @sizeOf(ModeInfo));
        try std.testing.expectEqual(@as(usize, 8), @sizeOf(Clip));
        try std.testing.expectEqual(@sizeOf(c.drm_clip_rect), @sizeOf(Clip));

        var m: ModeInfo = std.mem.zeroes(ModeInfo);
        m.clock = 148500;
        m.hdisplay = 1920;
        m.htotal = 2200;
        m.vdisplay = 1080;
        m.vtotal = 1125;
        m.type = drm.MODE_TYPE_PREFERRED;
        @memcpy(m.name[0..9], "1920x1080");
        const cm: *const c.drmModeModeInfo = @ptrCast(&m);
        try std.testing.expectEqual(m.clock, cm.clock);
        try std.testing.expectEqual(m.hdisplay, cm.hdisplay);
        try std.testing.expectEqual(m.htotal, cm.htotal);
        try std.testing.expectEqual(m.vtotal, cm.vtotal);
        try std.testing.expectEqual(m.type, cm.type);
        try std.testing.expectEqualSlices(u8, &m.name, &cm.name);
        const back: *const ModeInfo = @ptrCast(cm);
        try std.testing.expectEqual(m, back.*);
    }

    test "connector names match drmModeGetConnectorTypeName" {
        for (0..21) |t| {
            const ours = connectorTypeName(@intCast(t)).?;
            const theirs = std.mem.span(c.drmModeGetConnectorTypeName(@intCast(t)));
            try std.testing.expectEqualStrings(theirs, ours);
        }
    }
};

// With -lc and the drm-c module present (real-wrapper verification build),
// also compile and run the libdrm namespace. The hermetic build has
// link_libc=false, so the branch is never analyzed and drm-c stays optional.
test {
    if (comptime @import("builtin").link_libc) {
        std.testing.refAllDecls(libdrm);
    }
}

// ---------------------------------------------------------------------------
// Real libudev hotplug implementation (ROADMAP M5.5, recipes §9.2).
//
// libudev is already linked (build.zig). The extern declarations live inside
// this namespace so the hermetic test build never resolves them; they are
// referenced only through libudev.hotplugOps() (production) or the
// link_libc-gated test below.
// ---------------------------------------------------------------------------

pub const libudev = struct {
    extern fn udev_new() ?*anyopaque;
    extern fn udev_unref(*anyopaque) ?*anyopaque;
    extern fn udev_monitor_new_from_netlink(*anyopaque, [*:0]const u8) ?*anyopaque;
    extern fn udev_monitor_unref(*anyopaque) ?*anyopaque;
    extern fn udev_monitor_filter_add_match_subsystem_devtype(*anyopaque, [*:0]const u8, ?[*:0]const u8) c_int;
    extern fn udev_monitor_enable_receiving(*anyopaque) c_int;
    extern fn udev_monitor_get_fd(*anyopaque) c_int;
    extern fn udev_monitor_receive_device(*anyopaque) ?*anyopaque;
    extern fn udev_device_get_action(*anyopaque) ?[*:0]const u8;
    extern fn udev_device_get_property_value(*anyopaque, [*:0]const u8) ?[*:0]const u8;
    extern fn udev_device_unref(*anyopaque) ?*anyopaque;

    const Handle = struct { udev: *anyopaque, monitor: *anyopaque };

    /// HotplugOps backed by a udev netlink monitor on subsystem "drm".
    pub fn hotplugOps() HotplugOps {
        return .{
            .open = open,
            .close = close,
            .fd = fd,
            .next = next,
        };
    }

    fn open(_: ?*anyopaque) !*anyopaque {
        const udev = udev_new() orelse return error.Unsupported;
        errdefer _ = udev_unref(udev);
        const mon = udev_monitor_new_from_netlink(udev, "udev") orelse return error.Unsupported;
        errdefer _ = udev_monitor_unref(mon);
        if (udev_monitor_filter_add_match_subsystem_devtype(mon, "drm", null) < 0) return error.Unsupported;
        if (udev_monitor_enable_receiving(mon) < 0) return error.Unsupported;
        const h = try std.heap.c_allocator.create(Handle);
        h.* = .{ .udev = udev, .monitor = mon };
        return h;
    }

    fn close(_: ?*anyopaque, handle: *anyopaque) void {
        const h: *Handle = @ptrCast(@alignCast(handle));
        _ = udev_monitor_unref(h.monitor);
        _ = udev_unref(h.udev);
        std.heap.c_allocator.destroy(h);
    }

    fn fd(_: ?*anyopaque, handle: *anyopaque) i32 {
        const h: *Handle = @ptrCast(@alignCast(handle));
        return @intCast(udev_monitor_get_fd(h.monitor));
    }

    fn next(_: ?*anyopaque, handle: *anyopaque) !?HotplugEvent {
        const h: *Handle = @ptrCast(@alignCast(handle));
        while (true) {
            const dev = udev_monitor_receive_device(h.monitor) orelse return null;
            defer _ = udev_device_unref(dev);
            const action = udev_device_get_action(dev) orelse continue;
            const a = std.mem.span(action);
            if (std.mem.eql(u8, a, "add")) return .add;
            if (std.mem.eql(u8, a, "remove")) return .remove;
            if (std.mem.eql(u8, a, "change")) {
                if (udev_device_get_property_value(dev, "HOTPLUG")) |hp| {
                    if (std.mem.eql(u8, std.mem.span(hp), "1")) return .change;
                }
            }
            // Unrelated event: keep draining (recipes §9.2 HOTPLUG=1 filter).
        }
    }
};

test {
    if (comptime @import("builtin").link_libc) {
        std.testing.refAllDecls(libudev);
    }
}

// ---------------------------------------------------------------------------
// Hermetic tests: a fake device behind DrmOps. No libdrm, no /dev/dri.
// ---------------------------------------------------------------------------

const testing = std.testing;

const FakeProp = struct { id: u32, name: []const u8, value: u64 = 0 };

const FakeConn = struct {
    id: u32,
    type: u32,
    type_id: u32,
    connected: bool = true,
    mm_width: u32 = 530,
    mm_height: u32 = 300,
    modes: []const ModeInfo = &fake_modes_hdmi,
    encoder_id: u32 = 0,
    encoders: []const u32 = &.{},
    props: []const FakeProp = &fake_props_dpms,
};

const FakeEncoder = struct {
    id: u32,
    crtc_id: u32 = 0,
    possible_crtcs: u32 = 0,
};

fn fakeMode(w: u16, h: u16, clock: u32, htotal: u16, vtotal: u16, preferred: bool, name: []const u8) ModeInfo {
    var m: ModeInfo = std.mem.zeroes(ModeInfo);
    m.clock = clock;
    m.hdisplay = w;
    m.hsync_start = w + 88;
    m.hsync_end = w + 132;
    m.htotal = htotal;
    m.vdisplay = h;
    m.vsync_start = h + 4;
    m.vsync_end = h + 9;
    m.vtotal = vtotal;
    m.vrefresh = @intCast(@as(u64, clock) * 1000 / (@as(u64, htotal) * vtotal));
    m.type = if (preferred) drm.MODE_TYPE_PREFERRED else 0;
    @memcpy(m.name[0..name.len], name);
    return m;
}

const fake_mode_1024 = fakeMode(1024, 768, 65000, 1344, 806, false, "1024x768");
const fake_mode_1080 = fakeMode(1920, 1080, 148500, 2200, 1125, true, "1920x1080");
const fake_modes_hdmi = [_]ModeInfo{ fake_mode_1024, fake_mode_1080 };
const fake_modes_dp = [_]ModeInfo{fake_mode_1080};
const fake_props_dpms = [_]FakeProp{ .{ .id = 1, .name = "EDID" }, .{ .id = 7, .name = "DPMS", .value = 0 } };
const fake_props_none = [_]FakeProp{.{ .id = 1, .name = "EDID" }};

const fake_encoders = [_]FakeEncoder{
    .{ .id = 51, .crtc_id = 41, .possible_crtcs = 0b01 },
    .{ .id = 52, .crtc_id = 0, .possible_crtcs = 0b10 },
};

const fake_connectors = [_]FakeConn{
    .{ .id = 61, .type = 1, .type_id = 1, .connected = false, .encoder_id = 0, .encoders = &.{51}, .props = &fake_props_none },
    .{ .id = 62, .type = 11, .type_id = 1, .encoder_id = 51, .modes = &fake_modes_hdmi },
    .{ .id = 63, .type = 10, .type_id = 1, .encoder_id = 0, .encoders = &.{52}, .modes = &fake_modes_dp },
};

const FakeBuf = struct {
    handle: u32,
    fb_id: ?u32 = null,
    width: u32,
    height: u32,
    pitch: u32,
    size: u64,
    map: []align(page_align) u8,
    unmapped: bool = false,
    destroyed: bool = false,
};

const SetCrtcCall = struct {
    crtc_id: u32,
    fb_id: u32,
    connector_ids: []u32,
    mode: ?ModeInfo,
};

const FlipCall = struct { crtc_id: u32, fb_id: u32, flags: u32, user_data: u64 };
const PropCall = struct { connector_id: u32, prop_id: u32, value: u64 };
const DirtyCall = struct { fb_id: u32, clips: []Clip };
const CursorCall = struct { crtc_id: u32, handle: u32, width: u32, height: u32, hot_x: i32, hot_y: i32 };
const MoveCall = struct { crtc_id: u32, x: i32, y: i32 };

const Call = enum {
    open,
    close,
    set_master,
    drop_master,
    is_master,
    get_cap,
    set_client_cap,
    get_resources,
    get_connector,
    get_encoder,
    get_property,
    set_crtc,
    create_dumb,
    map_dumb,
    destroy_dumb,
    add_fb,
    rm_fb,
    dirty_fb,
    page_flip,
    set_property,
    set_cursor2,
    move_cursor,
    mmap,
    munmap,
    read,
    poll,
    get_crtc,
    get_plane_resources,
    get_plane,
    object_get_properties,
};

/// Fake DRM device: model + call recorder. Every DrmOps entry point lands
/// here; tests inspect the recorded calls and the buffer/event state.
const FakeDrm = struct {
    allocator: Allocator,

    // Model (mutable so tests can simulate hotplug / failures).
    crtcs: []const u32 = &.{ 41, 42 },
    connectors: []const FakeConn = &fake_connectors,
    encoders: []const FakeEncoder = &fake_encoders,
    dumb_cap: u64 = 1,
    cursor_w: ?u64 = 64,
    cursor_h: ?u64 = 64,
    pitch_pad: u32 = 0,
    cursor_pitch_pad: u32 = 0,
    fail_set_master: ?anyerror = null,
    fail_drop_master: ?anyerror = null,
    fail_dirty_fb: ?anyerror = null,
    fail_page_flip: ?anyerror = null,
    fail_set_cursor2: ?anyerror = null,
    auto_flip_event: bool = false,
    /// Whether a universal cursor plane exists (M5.7). Default true so the
    /// legacy cursor tests see a plane; set false for the no-plane path.
    cursor_plane_present: bool = true,
    /// Current CRTC mode for use-original-mode (M5.3); null = no mode bound.
    crtc_current_mode: ?ModeInfo = null,

    // State.
    master: bool = false,
    next_fd: i32 = 7,
    next_handle: u32 = 100,
    next_fb: u32 = 200,
    buffers: std.ArrayList(FakeBuf) = .empty,
    events: std.ArrayList(u8) = .empty,

    // Recordings.
    calls: std.ArrayList(Call) = .empty,
    opened_path: ?[]u8 = null,
    client_caps: std.ArrayList(struct { cap: u64, value: u64 }) = .empty,
    probe_flags: std.ArrayList(bool) = .empty,
    set_crtc_calls: std.ArrayList(SetCrtcCall) = .empty,
    flip_calls: std.ArrayList(FlipCall) = .empty,
    prop_calls: std.ArrayList(PropCall) = .empty,
    dirty_calls: std.ArrayList(DirtyCall) = .empty,
    cursor_calls: std.ArrayList(CursorCall) = .empty,
    move_calls: std.ArrayList(MoveCall) = .empty,

    const plane_type_prop: u32 = 90;

    fn deinit(self: *FakeDrm) void {
        for (self.buffers.items) |*b| {
            if (!b.unmapped) self.allocator.free(b.map);
        }
        self.buffers.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.calls.deinit(self.allocator);
        if (self.opened_path) |p| self.allocator.free(p);
        self.client_caps.deinit(self.allocator);
        self.probe_flags.deinit(self.allocator);
        for (self.set_crtc_calls.items) |s| self.allocator.free(s.connector_ids);
        self.set_crtc_calls.deinit(self.allocator);
        self.flip_calls.deinit(self.allocator);
        self.prop_calls.deinit(self.allocator);
        for (self.dirty_calls.items) |d| self.allocator.free(d.clips);
        self.dirty_calls.deinit(self.allocator);
        self.cursor_calls.deinit(self.allocator);
        self.move_calls.deinit(self.allocator);
    }

    fn record(self: *FakeDrm, call: Call) void {
        self.calls.append(self.allocator, call) catch @panic("fake: oom recording call");
    }

    fn count(self: *const FakeDrm, call: Call) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (c == call) n += 1;
        }
        return n;
    }

    fn ops(self: *FakeDrm) DrmOps {
        return .{
            .ctx = self,
            .open = open,
            .close = close,
            .set_master = setMaster,
            .drop_master = dropMaster,
            .is_master = isMaster,
            .get_cap = getCap,
            .set_client_cap = setClientCap,
            .get_resources = getResources,
            .get_connector = getConnector,
            .get_encoder = getEncoder,
            .get_property = getProperty,
            .set_crtc = setCrtc,
            .create_dumb = createDumb,
            .map_dumb = mapDumb,
            .destroy_dumb = destroyDumb,
            .add_fb = addFb,
            .rm_fb = rmFb,
            .dirty_fb = dirtyFb,
            .page_flip = pageFlip,
            .connector_set_property = connectorSetProperty,
            .set_cursor2 = setCursor2,
            .move_cursor = moveCursor,
            .get_crtc = getCrtc,
            .get_plane_resources = getPlaneResources,
            .get_plane = getPlane,
            .object_get_properties = objectGetProperties,
            .mmap = mmap,
            .munmap = munmap,
            .read = read,
            .poll = poll,
        };
    }

    fn cast(ctx: ?*anyopaque) *FakeDrm {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn bufByHandle(self: *FakeDrm, handle: u32) ?*FakeBuf {
        for (self.buffers.items) |*b| {
            if (b.handle == handle) return b;
        }
        return null;
    }

    /// Queue a 32-byte drm_event_vblank FLIP_COMPLETE (recipes §5.2 layout).
    fn queueFlipEvent(self: *FakeDrm, crtc_id: u32, user_data: u64) void {
        var ev: [32]u8 = std.mem.zeroes([32]u8);
        std.mem.writeInt(u32, ev[0..4], drm.EVENT_FLIP_COMPLETE, .little);
        std.mem.writeInt(u32, ev[4..8], 32, .little);
        std.mem.writeInt(u64, ev[8..16], user_data, .little);
        std.mem.writeInt(u32, ev[16..20], 0, .little); // tv_sec
        std.mem.writeInt(u32, ev[20..24], 0, .little); // tv_usec
        std.mem.writeInt(u32, ev[24..28], 1, .little); // sequence
        std.mem.writeInt(u32, ev[28..32], crtc_id, .little);
        self.events.appendSlice(self.allocator, &ev) catch @panic("fake: oom queueing event");
    }

    // -- DrmOps implementations --

    fn open(ctx: ?*anyopaque, path: [*:0]const u8) !i32 {
        const self = cast(ctx);
        self.record(.open);
        if (self.opened_path) |p| self.allocator.free(p);
        self.opened_path = null;
        self.opened_path = try self.allocator.dupe(u8, std.mem.span(path));
        const fd = self.next_fd;
        self.next_fd += 1;
        return fd;
    }

    fn close(ctx: ?*anyopaque, _: i32) void {
        cast(ctx).record(.close);
    }

    fn setMaster(ctx: ?*anyopaque, _: i32) !void {
        const self = cast(ctx);
        self.record(.set_master);
        if (self.fail_set_master) |err| return err;
        self.master = true;
    }

    fn dropMaster(ctx: ?*anyopaque, _: i32) !void {
        const self = cast(ctx);
        self.record(.drop_master);
        if (self.fail_drop_master) |err| return err;
        self.master = false;
    }

    fn isMaster(ctx: ?*anyopaque, _: i32) !bool {
        const self = cast(ctx);
        self.record(.is_master);
        return self.master;
    }

    fn getCap(ctx: ?*anyopaque, _: i32, cap: u64, value: *u64) !void {
        const self = cast(ctx);
        self.record(.get_cap);
        value.* = switch (cap) {
            drm.CAP_DUMB_BUFFER => self.dumb_cap,
            drm.CAP_CURSOR_WIDTH => self.cursor_w orelse return error.NotFound,
            drm.CAP_CURSOR_HEIGHT => self.cursor_h orelse return error.NotFound,
            else => return error.NotFound,
        };
    }

    fn setClientCap(ctx: ?*anyopaque, _: i32, cap: u64, value: u64) !void {
        const self = cast(ctx);
        self.record(.set_client_cap);
        try self.client_caps.append(self.allocator, .{ .cap = cap, .value = value });
    }

    fn getResources(ctx: ?*anyopaque, _: i32, allocator: Allocator) !Resources {
        const self = cast(ctx);
        self.record(.get_resources);
        const conn_ids = try allocator.alloc(u32, self.connectors.len);
        errdefer allocator.free(conn_ids);
        for (self.connectors, 0..) |cn, i| conn_ids[i] = cn.id;
        const enc_ids = try allocator.alloc(u32, self.encoders.len);
        errdefer allocator.free(enc_ids);
        for (self.encoders, 0..) |e, i| enc_ids[i] = e.id;
        const crtcs = try allocator.dupe(u32, self.crtcs);
        errdefer allocator.free(crtcs);
        return .{
            .crtcs = crtcs,
            .connectors = conn_ids,
            .encoders = enc_ids,
            .min_width = 32,
            .max_width = 8192,
            .min_height = 32,
            .max_height = 8192,
        };
    }

    fn getConnector(ctx: ?*anyopaque, _: i32, allocator: Allocator, connector_id: u32, force_probe: bool) !Connector {
        const self = cast(ctx);
        self.record(.get_connector);
        try self.probe_flags.append(self.allocator, force_probe);
        const cn = for (self.connectors) |*c| {
            if (c.id == connector_id) break c;
        } else return error.NotFound;
        const modes = try allocator.dupe(ModeInfo, cn.modes);
        errdefer allocator.free(modes);
        const props = try allocator.alloc(PropValue, cn.props.len);
        errdefer allocator.free(props);
        for (cn.props, 0..) |p, i| props[i] = .{ .id = p.id, .value = p.value };
        const encoders = try allocator.dupe(u32, cn.encoders);
        errdefer allocator.free(encoders);
        return .{
            .connector_id = cn.id,
            .encoder_id = cn.encoder_id,
            .connector_type = cn.type,
            .connector_type_id = cn.type_id,
            .connection = if (cn.connected) .connected else .disconnected,
            .mm_width = cn.mm_width,
            .mm_height = cn.mm_height,
            .modes = modes,
            .props = props,
            .encoders = encoders,
        };
    }

    fn getEncoder(ctx: ?*anyopaque, _: i32, encoder_id: u32) !Encoder {
        const self = cast(ctx);
        self.record(.get_encoder);
        const e = for (self.encoders) |*enc| {
            if (enc.id == encoder_id) break enc;
        } else return error.NotFound;
        return .{
            .encoder_id = e.id,
            .encoder_type = 0,
            .crtc_id = e.crtc_id,
            .possible_crtcs = e.possible_crtcs,
            .possible_clones = 0,
        };
    }

    fn getProperty(ctx: ?*anyopaque, _: i32, prop_id: u32) !Property {
        const self = cast(ctx);
        self.record(.get_property);
        if (prop_id == plane_type_prop) {
            var prop: Property = .{ .prop_id = prop_id, .flags = 0, .name = @splat(0) };
            @memcpy(prop.name[0..4], "type");
            return prop;
        }
        for (self.connectors) |cn| {
            for (cn.props) |p| {
                if (p.id == prop_id) {
                    var prop: Property = .{ .prop_id = p.id, .flags = 0, .name = @splat(0) };
                    @memcpy(prop.name[0..p.name.len], p.name);
                    return prop;
                }
            }
        }
        return error.NotFound;
    }

    fn setCrtc(ctx: ?*anyopaque, _: i32, crtc_id: u32, fb_id: u32, _: u32, _: u32, connector_ids: []const u32, mode: ?*const ModeInfo) !void {
        const self = cast(ctx);
        self.record(.set_crtc);
        const ids = try self.allocator.dupe(u32, connector_ids);
        errdefer self.allocator.free(ids);
        try self.set_crtc_calls.append(self.allocator, .{
            .crtc_id = crtc_id,
            .fb_id = fb_id,
            .connector_ids = ids,
            .mode = if (mode) |m| m.* else null,
        });
    }

    fn createDumb(ctx: ?*anyopaque, _: i32, width: u32, height: u32, bpp: u32) !DumbBuffer {
        const self = cast(ctx);
        self.record(.create_dumb);
        if (bpp != 32) return error.InvalidArgument;
        const is_cursor = width == (self.cursor_w orelse 0) and height == (self.cursor_h orelse 0);
        const pad = if (is_cursor) self.cursor_pitch_pad else self.pitch_pad;
        const pitch = width * 4 + pad;
        const size: u64 = @as(u64, pitch) * height;
        const map = try self.allocator.alignedAlloc(u8, .fromByteUnits(page_align), @intCast(size));
        errdefer self.allocator.free(map);
        const handle = self.next_handle;
        self.next_handle += 1;
        try self.buffers.append(self.allocator, .{
            .handle = handle,
            .width = width,
            .height = height,
            .pitch = pitch,
            .size = size,
            .map = map,
        });
        return .{ .handle = handle, .pitch = pitch, .size = size };
    }

    fn mapDumb(ctx: ?*anyopaque, _: i32, handle: u32) !u64 {
        cast(ctx).record(.map_dumb);
        // Fake mmap offset: the handle itself.
        return handle;
    }

    fn destroyDumb(ctx: ?*anyopaque, _: i32, handle: u32) !void {
        const self = cast(ctx);
        self.record(.destroy_dumb);
        const b = self.bufByHandle(handle) orelse return error.NotFound;
        b.destroyed = true;
    }

    fn addFb(ctx: ?*anyopaque, _: i32, width: u32, height: u32, depth: u8, bpp: u8, pitch: u32, handle: u32) !u32 {
        const self = cast(ctx);
        self.record(.add_fb);
        if (depth != 24 or bpp != 32) return error.InvalidArgument;
        const b = self.bufByHandle(handle) orelse return error.NotFound;
        if (b.width != width or b.height != height or b.pitch != pitch) return error.InvalidArgument;
        const id = self.next_fb;
        self.next_fb += 1;
        b.fb_id = id;
        return id;
    }

    fn rmFb(ctx: ?*anyopaque, _: i32, fb_id: u32) !void {
        const self = cast(ctx);
        self.record(.rm_fb);
        for (self.buffers.items) |*b| {
            if (b.fb_id == fb_id) {
                b.fb_id = null;
                return;
            }
        }
        return error.NotFound;
    }

    fn dirtyFb(ctx: ?*anyopaque, _: i32, fb_id: u32, clips: []const Clip) !void {
        const self = cast(ctx);
        self.record(.dirty_fb);
        const copy = try self.allocator.dupe(Clip, clips);
        errdefer self.allocator.free(copy);
        try self.dirty_calls.append(self.allocator, .{ .fb_id = fb_id, .clips = copy });
        if (self.fail_dirty_fb) |err| return err;
    }

    fn pageFlip(ctx: ?*anyopaque, _: i32, crtc_id: u32, fb_id: u32, flags: u32, user_data: u64) !void {
        const self = cast(ctx);
        self.record(.page_flip);
        try self.flip_calls.append(self.allocator, .{ .crtc_id = crtc_id, .fb_id = fb_id, .flags = flags, .user_data = user_data });
        if (self.fail_page_flip) |err| return err;
        if (self.auto_flip_event) self.queueFlipEvent(crtc_id, user_data);
    }

    fn connectorSetProperty(ctx: ?*anyopaque, _: i32, connector_id: u32, prop_id: u32, value: u64) !void {
        const self = cast(ctx);
        self.record(.set_property);
        try self.prop_calls.append(self.allocator, .{ .connector_id = connector_id, .prop_id = prop_id, .value = value });
    }

    fn setCursor2(ctx: ?*anyopaque, _: i32, crtc_id: u32, handle: u32, width: u32, height: u32, hot_x: i32, hot_y: i32) !void {
        const self = cast(ctx);
        self.record(.set_cursor2);
        try self.cursor_calls.append(self.allocator, .{ .crtc_id = crtc_id, .handle = handle, .width = width, .height = height, .hot_x = hot_x, .hot_y = hot_y });
        if (self.fail_set_cursor2) |err| return err;
    }

    fn moveCursor(ctx: ?*anyopaque, _: i32, crtc_id: u32, x: i32, y: i32) !void {
        const self = cast(ctx);
        self.record(.move_cursor);
        try self.move_calls.append(self.allocator, .{ .crtc_id = crtc_id, .x = x, .y = y });
    }

    fn mmap(ctx: ?*anyopaque, _: i32, len: usize, offset: u64) ![]align(page_align) u8 {
        const self = cast(ctx);
        self.record(.mmap);
        const b = self.bufByHandle(@intCast(offset)) orelse return error.NotFound;
        if (@as(u64, len) != b.size) return error.InvalidArgument;
        return b.map;
    }

    fn munmap(ctx: ?*anyopaque, mem: []align(page_align) u8) void {
        const self = cast(ctx);
        self.record(.munmap);
        for (self.buffers.items) |*b| {
            if (b.map.ptr == mem.ptr) {
                b.unmapped = true;
                self.allocator.free(mem);
                return;
            }
        }
        @panic("fake: munmap of unknown mapping");
    }

    fn read(ctx: ?*anyopaque, _: i32, buf: []u8) !usize {
        const self = cast(ctx);
        self.record(.read);
        if (self.events.items.len == 0) return error.WouldBlock;
        const n = @min(buf.len, self.events.items.len);
        @memcpy(buf[0..n], self.events.items[0..n]);
        const remaining = self.events.items.len - n;
        std.mem.copyForwards(u8, self.events.items[0..remaining], self.events.items[n..]);
        self.events.shrinkRetainingCapacity(remaining);
        return n;
    }

    fn poll(ctx: ?*anyopaque, _: i32, _: i32) !void {
        cast(ctx).record(.poll);
    }

    fn getCrtc(ctx: ?*anyopaque, _: i32, crtc_id: u32) !CrtcState {
        const self = cast(ctx);
        self.record(.get_crtc);
        const m = self.crtc_current_mode orelse std.mem.zeroes(ModeInfo);
        return .{
            .crtc_id = crtc_id,
            .buffer_id = if (self.crtc_current_mode != null) 1 else 0,
            .width = m.hdisplay,
            .height = m.vdisplay,
            .mode_valid = self.crtc_current_mode != null,
            .mode = m,
        };
    }

    fn getPlaneResources(ctx: ?*anyopaque, _: i32, allocator: Allocator) !PlaneResources {
        const self = cast(ctx);
        self.record(.get_plane_resources);
        const ids: []const u32 = if (self.cursor_plane_present) &.{ 70, 71 } else &.{70};
        const planes = try allocator.dupe(u32, ids);
        return .{ .planes = planes };
    }

    fn getPlane(ctx: ?*anyopaque, _: i32, plane_id: u32) !Plane {
        const self = cast(ctx);
        self.record(.get_plane);
        return .{ .plane_id = plane_id, .crtc_id = 0, .fb_id = 0, .possible_crtcs = 0b11 };
    }

    fn objectGetProperties(ctx: ?*anyopaque, _: i32, allocator: Allocator, object_id: u32, _: u32) !ObjectProperties {
        const self = cast(ctx);
        self.record(.object_get_properties);
        const props = try allocator.alloc(PropValue, 1);
        errdefer allocator.free(props);
        const typ: u64 = if (object_id == 71) drm.PLANE_TYPE_CURSOR else drm.PLANE_TYPE_PRIMARY;
        props[0] = .{ .id = plane_type_prop, .value = typ };
        return .{ .props = props };
    }
};

/// init + takeMaster + setMode on the default fake model (HDMI-A-1,
/// preferred 1920x1080). Returns the backend; caller deinits.
fn setupActive(a: Allocator, fake: *FakeDrm) !*Drm2d {
    const d = try Drm2d.init(a, "/dev/dri/card0", fake.ops());
    errdefer d.deinit();
    try d.takeMaster();
    try d.setMode(1, 1);
    return d;
}

test "init: enumerates, picks first connected + preferred, defers master" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();

    const d = try Drm2d.init(a, "/dev/dri/card0", fake.ops());
    defer d.deinit();

    // Master deferred to activate (recipes §1.4, assignment).
    try testing.expectEqual(@as(usize, 0), fake.count(.set_master));
    try testing.expect(!d.isMaster());
    // Read-only probe before master (constraint #3).
    for (fake.probe_flags.items) |p| try testing.expect(!p);
    // Universal planes cap set before enumeration (constraint #7).
    try testing.expectEqual(@as(usize, 1), fake.client_caps.items.len);
    try testing.expectEqual(drm.CLIENT_CAP_UNIVERSAL_PLANES, fake.client_caps.items[0].cap);
    try testing.expectEqual(@as(u64, 1), fake.client_caps.items[0].value);
    try testing.expectEqualStrings("/dev/dri/card0", fake.opened_path.?);

    // First connected connector with modes: HDMI-A-1 (id 62), not VGA.
    try testing.expectEqual(@as(?usize, 1), d.chosen);
    const infos = d.infos;
    try testing.expectEqual(@as(usize, 3), infos.len);
    try testing.expectEqualStrings("VGA-1", infos[0].name);
    try testing.expectEqualStrings("HDMI-A-1", infos[1].name);
    try testing.expectEqualStrings("DP-1", infos[2].name);
    try testing.expectEqualStrings("card0", infos[1].card_name);
    try testing.expect(!infos[0].connected);
    try testing.expect(infos[1].connected);
    try testing.expectEqual(@as(usize, 2), infos[1].modes.len);
    // Preferred = the DRM_MODE_TYPE_PREFERRED mode, not modes[0].
    try testing.expectEqual(@as(?usize, 1), infos[1].preferred_mode);
    try testing.expectEqual(@as(?usize, null), infos[1].current_mode);
    const m = infos[1].modes[1];
    try testing.expectEqual(@as(u32, 1920), m.width_px);
    try testing.expectEqual(@as(u32, 1080), m.height_px);
    try testing.expectEqual(@as(u32, 60000), m.refresh_mhz);
    try testing.expectEqual(@as(u32, 530), m.width_mm);
    try testing.expectEqual(@as(u32, 300), m.height_mm);
    // DP-1 has a single preferred mode.
    try testing.expectEqual(@as(?usize, 0), infos[2].preferred_mode);
}

test "init: null card path defaults to /dev/dri/card0" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try Drm2d.init(a, null, fake.ops());
    defer d.deinit();
    try testing.expectEqualStrings("/dev/dri/card0", fake.opened_path.?);
}

test "init: no connected display fails and closes the fd" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    var conns = [_]FakeConn{fake_connectors[0]};
    conns[0].connected = false;
    fake.connectors = &conns;
    try testing.expectError(error.NoConnectedDisplay, Drm2d.init(a, "/dev/dri/card0", fake.ops()));
    try testing.expectEqual(@as(usize, 1), fake.count(.close));
}

test "init: driver without dumb buffers is unsupported" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    fake.dumb_cap = 0;
    try testing.expectError(error.Unsupported, Drm2d.init(a, "/dev/dri/card0", fake.ops()));
    try testing.expectEqual(@as(usize, 1), fake.count(.close));
}

test "setMode: double buffers, SetCrtc before flips, dirtyfb probe" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();

    try testing.expect(d.isMaster());
    // takeMaster re-probed with force (constraint #3).
    try testing.expect(fake.probe_flags.items[fake.probe_flags.items.len - 1]);
    // Two dumb buffers at the mode size, 32 bpp, each AddFB'd and mapped.
    try testing.expectEqual(@as(usize, 2), fake.count(.create_dumb));
    try testing.expectEqual(@as(usize, 2), fake.count(.add_fb));
    try testing.expectEqual(@as(usize, 2), fake.count(.mmap));
    try testing.expectEqual(@as(usize, 2), fake.buffers.items.len);
    for (fake.buffers.items) |b| {
        try testing.expectEqual(@as(u32, 1920), b.width);
        try testing.expectEqual(@as(u32, 1080), b.height);
        try testing.expect(b.fb_id != null);
    }
    // SetCrtc attached fb0 + the preferred mode to connector 62 on crtc 41.
    try testing.expectEqual(@as(usize, 1), fake.set_crtc_calls.items.len);
    const sc = fake.set_crtc_calls.items[0];
    try testing.expectEqual(@as(u32, 41), sc.crtc_id);
    try testing.expectEqual(fake.buffers.items[0].fb_id.?, sc.fb_id);
    try testing.expectEqualSlices(u32, &.{62}, sc.connector_ids);
    try testing.expectEqual(@as(u16, 1920), sc.mode.?.hdisplay);
    try testing.expectEqual(@as(u16, 1080), sc.mode.?.vdisplay);
    // DirtyFB probed once with no clips; supported on the fake.
    try testing.expectEqual(@as(usize, 1), fake.dirty_calls.items.len);
    try testing.expectEqual(@as(usize, 0), fake.dirty_calls.items[0].clips.len);
    try testing.expect(d.dirtyfb_supported);
    try testing.expect(d.needsFullRedraw());
    try testing.expectEqual(@as(?usize, 1), d.infos[1].current_mode);
    // No flip submitted yet.
    try testing.expectEqual(@as(usize, 0), fake.count(.page_flip));
}

test "setMode: padded pitch is honored by the framebuffer view" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    fake.pitch_pad = 64;
    const d = try setupActive(a, &fake);
    defer d.deinit();
    const back = try d.beginFrame();
    try testing.expectEqual(@as(u32, 1920 * 4 + 64), back.pitch);
    try testing.expectEqual(@as(usize, back.pitch * 1080), back.mem.len);
    // Row access goes through the pitch: writing row 1 lands at pitch, not w*4.
    back.set(0, 1, 0xAABBCCDD);
    const map = fake.buffers.items[1].map;
    try testing.expectEqual(@as(u32, 0xAABBCCDD), std.mem.readInt(u32, map[back.pitch..][0..4], .little));
}

test "setMode: invalid indices and disconnected connector rejected" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try Drm2d.init(a, "/dev/dri/card0", fake.ops());
    defer d.deinit();
    try d.takeMaster();
    try testing.expectError(error.InvalidConnector, d.setMode(9, 0));
    try testing.expectError(error.NotConnected, d.setMode(0, 0));
    try testing.expectError(error.InvalidMode, d.setMode(1, 9));
}

test "frame loop: alternates buffers, one outstanding flip" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();

    // Frame 1: draw into the back buffer (buf1, front=0).
    const f1 = try d.beginFrame();
    try testing.expectEqual(@intFromPtr(fake.buffers.items[1].map.ptr), @intFromPtr(f1.mem.ptr));
    f1.set(3, 2, 0x11223344);
    try testing.expectEqual(@as(u32, 0x11223344), std.mem.readInt(u32, fake.buffers.items[1].map[2 * f1.pitch + 12 ..][0..4], .little));

    try d.endFrame(&.{.{ .x = 0, .y = 0, .w = 1920, .h = 1080 }});
    try testing.expect(d.flipPending());
    try testing.expectEqual(@as(usize, 1), fake.flip_calls.items.len);
    try testing.expectEqual(fake.buffers.items[1].fb_id.?, fake.flip_calls.items[0].fb_id);
    try testing.expectEqual(drm.PAGE_FLIP_EVENT, fake.flip_calls.items[0].flags);
    try testing.expectEqual(@as(u32, 41), fake.flip_calls.items[0].crtc_id);

    // While pending: no drawing, no second flip (constraint #4).
    try testing.expectError(error.Busy, d.beginFrame());
    try testing.expectError(error.Busy, d.endFrame(&.{}));
    try testing.expectEqual(@as(usize, 1), fake.flip_calls.items.len);

    // FLIP_COMPLETE swaps front/back and clears pending.
    fake.queueFlipEvent(41, Drm2d.flip_cookie);
    try d.readEvents();
    try testing.expect(!d.flipPending());

    // Frame 2: the other buffer.
    const f2 = try d.beginFrame();
    try testing.expectEqual(@intFromPtr(fake.buffers.items[0].map.ptr), @intFromPtr(f2.mem.ptr));
    try testing.expect(@intFromPtr(f1.mem.ptr) != @intFromPtr(f2.mem.ptr));
    try d.endFrame(&.{});
    try testing.expectEqual(fake.buffers.items[0].fb_id.?, fake.flip_calls.items[1].fb_id);
    fake.queueFlipEvent(41, Drm2d.flip_cookie);
    try d.readEvents();

    // Frame 3: back to the first buffer — strict alternation.
    const f3 = try d.beginFrame();
    try testing.expectEqual(@intFromPtr(f1.mem.ptr), @intFromPtr(f3.mem.ptr));
}

test "flip: EBUSY keeps pending set, never clears it" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();

    // First flip completes normally.
    _ = try d.beginFrame();
    try d.endFrame(&.{});
    fake.queueFlipEvent(41, Drm2d.flip_cookie);
    try d.readEvents();
    try testing.expect(!d.flipPending());

    // Kernel says a flip is still in flight: pending must be (re)set and
    // stay set; the frame is dropped (recipes §5.5).
    fake.fail_page_flip = error.Busy;
    _ = try d.beginFrame();
    try testing.expectError(error.Busy, d.endFrame(&.{}));
    try testing.expect(d.flipPending());
    fake.fail_page_flip = null;

    // An event for a different CRTC/cookie does not clear our pending flag.
    fake.queueFlipEvent(999, 0xDEAD);
    try d.readEvents();
    try testing.expect(d.flipPending());

    // Only our FLIP_COMPLETE clears it.
    fake.queueFlipEvent(41, Drm2d.flip_cookie);
    try d.readEvents();
    try testing.expect(!d.flipPending());
}

test "flip: crtc_id 0 event (old kernel) matches by cookie" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();
    _ = try d.beginFrame();
    try d.endFrame(&.{});
    fake.queueFlipEvent(0, Drm2d.flip_cookie);
    try d.readEvents();
    try testing.expect(!d.flipPending());
}

test "events: vblank ignored, malformed length rejected" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();
    _ = try d.beginFrame();
    try d.endFrame(&.{});

    // A VBLANK event (type 1) does not complete the flip.
    var ev: [32]u8 = std.mem.zeroes([32]u8);
    std.mem.writeInt(u32, ev[0..4], drm.EVENT_VBLANK, .little);
    std.mem.writeInt(u32, ev[4..8], 32, .little);
    std.mem.writeInt(u64, ev[8..16], Drm2d.flip_cookie, .little);
    std.mem.writeInt(u32, ev[28..32], 41, .little);
    try fake.events.appendSlice(a, &ev);
    try d.readEvents();
    try testing.expect(d.flipPending());

    // Truncated event stream: length runs past the buffer.
    fake.events.clearRetainingCapacity();
    var bad: [12]u8 = std.mem.zeroes([12]u8);
    std.mem.writeInt(u32, bad[0..4], drm.EVENT_FLIP_COMPLETE, .little);
    std.mem.writeInt(u32, bad[4..8], 32, .little);
    try fake.events.appendSlice(a, &bad);
    try testing.expectError(error.MalformedEvent, d.readEvents());
}

test "waitFlip: completes on event, bounded timeout otherwise" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();

    // No pending flip: no-op.
    try d.waitFlip();
    try testing.expectEqual(@as(usize, 0), fake.count(.poll));

    _ = try d.beginFrame();
    try d.endFrame(&.{});
    fake.queueFlipEvent(41, Drm2d.flip_cookie);
    try d.waitFlip();
    try testing.expect(!d.flipPending());

    // No event ever: 1000 ms cap (10 x 100 ms polls), flag stays set.
    _ = try d.beginFrame();
    try d.endFrame(&.{});
    try testing.expectError(error.Timeout, d.waitFlip());
    try testing.expect(d.flipPending());
    try testing.expectEqual(@as(usize, 10), fake.count(.poll));
}

test "dirtyfb: ENOSYS tolerated, support disabled, flip still works" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    fake.fail_dirty_fb = error.Unsupported; // ENOSYS maps to Unsupported
    const d = try setupActive(a, &fake);
    defer d.deinit();

    // The setMode probe hit ENOSYS: support off, modeset unaffected.
    try testing.expect(!d.dirtyfb_supported);
    _ = try d.beginFrame();
    try d.endFrame(&.{.{ .x = 0, .y = 0, .w = 10, .h = 10 }});
    try testing.expect(d.flipPending());
    // Only the probe call, no per-frame damage calls.
    try testing.expectEqual(@as(usize, 1), fake.dirty_calls.items.len);
}

test "dirtyfb: clips are half-open u16, clipped, skipped after modeset" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();

    // First frame after modeset: full redraw, no damage clips (constraint #10).
    _ = try d.beginFrame();
    try d.endFrame(&.{.{ .x = 5, .y = 5, .w = 10, .h = 10 }});
    try testing.expectEqual(@as(usize, 1), fake.dirty_calls.items.len); // probe only
    fake.queueFlipEvent(41, Drm2d.flip_cookie);
    try d.readEvents();

    // Second frame: damage converted to half-open clips, out-of-bounds
    // trimmed, empties dropped, all against the fb being flipped.
    _ = try d.beginFrame();
    const back_fb = fake.buffers.items[0].fb_id.?;
    try d.endFrame(&.{
        .{ .x = 10, .y = 20, .w = 30, .h = 40 },
        .{ .x = 1900, .y = 1060, .w = 100, .h = 100 }, // clipped to 1920x1080
        .{ .x = 5000, .y = 5000, .w = 10, .h = 10 }, // fully outside: dropped
        .{ .x = 0, .y = 0, .w = 0, .h = 5 }, // empty: dropped
    });
    try testing.expectEqual(@as(usize, 2), fake.dirty_calls.items.len);
    const dc = fake.dirty_calls.items[1];
    try testing.expectEqual(back_fb, dc.fb_id);
    try testing.expectEqual(@as(usize, 2), dc.clips.len);
    try testing.expectEqual(Clip{ .x1 = 10, .y1 = 20, .x2 = 40, .y2 = 60 }, dc.clips[0]);
    try testing.expectEqual(Clip{ .x1 = 1900, .y1 = 1060, .x2 = 1920, .y2 = 1080 }, dc.clips[1]);
}

test "dirtyfb: empty damage presents everything without a hint" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();
    _ = try d.beginFrame();
    try d.endFrame(&.{});
    try testing.expectEqual(@as(usize, 1), fake.dirty_calls.items.len); // probe only
    try testing.expectEqual(@as(usize, 1), fake.flip_calls.items.len);
}

test "dpms: property set, re-applied after setMode, wake re-modesets" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();

    // Off through the connector's DPMS property (id 7, value 3).
    try d.setDpms(.off);
    try testing.expectEqual(DpmsState.off, d.dpmsState());
    try testing.expectEqual(@as(usize, 1), fake.prop_calls.items.len);
    try testing.expectEqual(PropCall{ .connector_id = 62, .prop_id = 7, .value = 3 }, fake.prop_calls.items[0]);

    // Flips are refused while off (recipes §7.2.3).
    try testing.expectError(error.DisplayOff, d.endFrame(&.{}));

    // SetCrtc forces DPMS on: setMode must re-apply the tracked state.
    const modesets_before = fake.set_crtc_calls.items.len;
    try d.setMode(1, 1);
    try testing.expectEqual(modesets_before + 1, fake.set_crtc_calls.items.len);
    try testing.expectEqual(@as(usize, 2), fake.prop_calls.items.len);
    try testing.expectEqual(PropCall{ .connector_id = 62, .prop_id = 7, .value = 3 }, fake.prop_calls.items[1]);
    try testing.expectEqual(DpmsState.off, d.dpmsState());

    // Wake: property On, then a full SetCrtc before any flip (constraint #5).
    try d.setDpms(.on);
    try testing.expectEqual(@as(usize, 3), fake.prop_calls.items.len);
    try testing.expectEqual(PropCall{ .connector_id = 62, .prop_id = 7, .value = 0 }, fake.prop_calls.items[2]);
    try testing.expectEqual(modesets_before + 2, fake.set_crtc_calls.items.len);
    try testing.expect(d.needsFullRedraw());
    _ = try d.beginFrame();
    try d.endFrame(&.{});
    try testing.expect(d.flipPending());
}

test "dpms: connector without DPMS property is unsupported" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    var conns = fake_connectors;
    conns[2].props = &fake_props_none;
    fake.connectors = &conns;
    const d = try Drm2d.init(a, "/dev/dri/card0", fake.ops());
    defer d.deinit();
    try d.takeMaster();
    try d.setMode(2, 0); // DP-1, no DPMS prop
    try testing.expectError(error.Unsupported, d.setDpms(.off));
    // Before any modeset there is no active connector.
    const d2 = try Drm2d.init(a, "/dev/dri/card0", fake.ops());
    defer d2.deinit();
    try testing.expectError(error.NoActiveDisplay, d2.setDpms(.off));
}

test "cursor: caps size, legacy set/move, pixel copy, hide" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();

    try testing.expect(d.supportsHwCursor());
    var img = try Framebuffer.create(a, 32, 32, .argb8888, null);
    defer img.destroy(a);
    img.set(0, 0, 0x80FF0000);
    img.set(31, 31, 0x12345678);

    try d.setCursor(&img, 10, 20);
    // Dumb buffer at the cap size, ARGB by legacy convention.
    try testing.expectEqual(@as(usize, 3), fake.count(.create_dumb)); // 2 scanout + 1 cursor
    const cb = fake.buffers.items[2];
    try testing.expectEqual(@as(u32, 64), cb.width);
    try testing.expectEqual(@as(u32, 64), cb.height);
    try testing.expectEqual(@as(u32, 64 * 4), cb.pitch);
    try testing.expectEqual(@as(usize, 1), fake.cursor_calls.items.len);
    const cc = fake.cursor_calls.items[0];
    try testing.expectEqual(@as(u32, 41), cc.crtc_id);
    try testing.expectEqual(cb.handle, cc.handle);
    try testing.expectEqual(@as(u32, 64), cc.width);
    try testing.expectEqual(@as(u32, 64), cc.height);
    try testing.expectEqual(@as(i32, 0), cc.hot_x);
    try testing.expectEqual(@as(i32, 0), cc.hot_y);
    try testing.expectEqual(MoveCall{ .crtc_id = 41, .x = 10, .y = 20 }, fake.move_calls.items[0]);
    // Top-left overlap copied without scaling; rest transparent.
    try testing.expectEqual(@as(u32, 0x80FF0000), std.mem.readInt(u32, cb.map[0..4], .little));
    try testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, cb.map[31 * cb.pitch + 31 * 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, cb.map[63 * cb.pitch + 63 * 4 ..][0..4], .little));

    // Hide: handle 0.
    try d.setCursor(null, 0, 0);
    try testing.expectEqual(@as(usize, 2), fake.cursor_calls.items.len);
    try testing.expectEqual(@as(u32, 0), fake.cursor_calls.items[1].handle);
}

test "cursor: xrgb image gets opaque alpha" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();
    var img = try Framebuffer.create(a, 8, 8, .xrgb8888, null);
    defer img.destroy(a);
    img.set(1, 1, 0x00AABBCC);
    try d.setCursor(&img, 0, 0);
    const cb = fake.buffers.items[2];
    try testing.expectEqual(@as(u32, 0xFFAABBCC), std.mem.readInt(u32, cb.map[cb.pitch + 4 ..][0..4], .little));
}

test "cursor: padded pitch falls back to software" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    fake.cursor_pitch_pad = 64;
    const d = try setupActive(a, &fake);
    defer d.deinit();
    var img = try Framebuffer.create(a, 8, 8, .argb8888, null);
    defer img.destroy(a);
    try testing.expect(d.supportsHwCursor());
    // Constraint #9: pitch != width*4 shears the legacy cursor wrap.
    try testing.expectError(error.Unsupported, d.setCursor(&img, 0, 0));
    try testing.expect(!d.supportsHwCursor());
    try testing.expectError(error.Unsupported, d.setCursor(&img, 0, 0));
}

test "cursor: missing caps or device failure falls back to software" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    fake.cursor_w = null;
    const d = try setupActive(a, &fake);
    defer d.deinit();
    try testing.expect(!d.supportsHwCursor());
    var img = try Framebuffer.create(a, 8, 8, .argb8888, null);
    defer img.destroy(a);
    try testing.expectError(error.Unsupported, d.setCursor(&img, 0, 0));

    // Separate device: caps present but SetCursor2 fails (e.g. bochs has no
    // cursor plane at all, recipes §8) -> permanent software fallback.
    var fake2: FakeDrm = .{ .allocator = a };
    defer fake2.deinit();
    fake2.fail_set_cursor2 = error.Unsupported;
    const d2 = try setupActive(a, &fake2);
    defer d2.deinit();
    try testing.expect(d2.supportsHwCursor());
    try testing.expectError(error.Unsupported, d2.setCursor(&img, 0, 0));
    try testing.expect(!d2.supportsHwCursor());
}

test "master handoff: drop waits flip and hides cursor, take re-modesets" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();

    var img = try Framebuffer.create(a, 8, 8, .argb8888, null);
    defer img.destroy(a);
    try d.setCursor(&img, 5, 6);
    _ = try d.beginFrame();
    try d.endFrame(&.{});
    try testing.expect(d.flipPending());

    // The flip completes during the drop wait.
    fake.queueFlipEvent(41, Drm2d.flip_cookie);
    try d.dropMaster();
    try testing.expect(!d.isMaster());
    try testing.expect(!d.flipPending());
    try testing.expectEqual(@as(usize, 1), fake.count(.drop_master));
    // Cursor hidden before the drop (recipes §1.4).
    try testing.expectEqual(@as(u32, 0), fake.cursor_calls.items[fake.cursor_calls.items.len - 1].handle);

    // Take again: master + forced re-probe + SetCrtc re-applied.
    const modesets_before = fake.set_crtc_calls.items.len;
    try d.takeMaster();
    try testing.expect(d.isMaster());
    try testing.expectEqual(modesets_before + 1, fake.set_crtc_calls.items.len);
    try testing.expect(d.needsFullRedraw());

    // EINVAL on drop means already dropped: success (recipes §1.2).
    fake.fail_drop_master = error.InvalidArgument;
    try d.dropMaster();
    try testing.expect(!d.isMaster());
}

test "master: set_master EBUSY propagates for the seat retry timer" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    fake.fail_set_master = error.Busy;
    const d = try Drm2d.init(a, "/dev/dri/card0", fake.ops());
    defer d.deinit();
    try testing.expectError(error.Busy, d.takeMaster());
    try testing.expect(!d.isMaster());
}

test "teardown: munmap -> RmFB -> DestroyDumb per buffer, then close" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    var img = try Framebuffer.create(a, 8, 8, .argb8888, null);
    defer img.destroy(a);
    try d.setCursor(&img, 0, 0);

    const calls_before = fake.calls.items.len;
    d.deinit();

    // Extract the teardown tail and check the ordering (constraint #13).
    const tail = fake.calls.items[calls_before..];
    var pos: usize = 0;
    const expectNext = struct {
        fn f(items: []const Call, p: *usize, want: Call) !void {
            while (p.* < items.len and items[p.*] != want) p.* += 1;
            if (p.* >= items.len) return error.TestUnexpectedResult;
            p.* += 1;
        }
    }.f;
    // Cursor first: munmap + destroy (no fb for legacy cursors).
    try expectNext(tail, &pos, .munmap);
    try expectNext(tail, &pos, .destroy_dumb);
    // Master dropped before buffer teardown (recipes §11).
    try expectNext(tail, &pos, .drop_master);
    // Each scanout buffer: munmap -> rm_fb -> destroy_dumb.
    try expectNext(tail, &pos, .munmap);
    try expectNext(tail, &pos, .rm_fb);
    try expectNext(tail, &pos, .destroy_dumb);
    try expectNext(tail, &pos, .munmap);
    try expectNext(tail, &pos, .rm_fb);
    try expectNext(tail, &pos, .destroy_dumb);
    // Close is the last device call.
    try expectNext(tail, &pos, .close);
    try testing.expectEqual(tail.len, pos);
    for (fake.buffers.items) |b| {
        try testing.expect(b.unmapped);
        try testing.expect(b.destroyed);
    }
}

test "hotplug: re-enumeration reflects disconnect, defers teardown mid-flip" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();

    // Unplug HDMI while a flip is in flight: buffers must survive (#12).
    _ = try d.beginFrame();
    try d.endFrame(&.{});
    var conns = fake_connectors;
    conns[1].connected = false;
    fake.connectors = &conns;
    const infos = try d.connectors();
    try testing.expect(!infos[1].connected);
    try testing.expect(d.bufs_live);
    try testing.expect(d.active != null);
    // No reopen, no master retake (constraint #14).
    try testing.expectEqual(@as(usize, 1), fake.count(.open));
    try testing.expectEqual(@as(usize, 1), fake.count(.set_master));

    // Flip completes; the next re-enumeration tears the display down.
    fake.queueFlipEvent(41, Drm2d.flip_cookie);
    try d.readEvents();
    _ = try d.connectors();
    try testing.expect(!d.bufs_live);
    try testing.expect(d.active == null);
    try testing.expectError(error.NoActiveDisplay, d.beginFrame());
}

test "vtable: backend interface dispatches to the same state" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try Drm2d.init(a, "/dev/dri/card0", fake.ops());
    const b = d.backend();
    defer b.deinit();

    try d.takeMaster();
    const infos = try b.connectors();
    try testing.expectEqual(@as(usize, 3), infos.len);
    try b.setMode(1, 1);
    const frame = try b.beginFrame();
    try testing.expectEqual(@as(u32, 1920), frame.width);
    try b.endFrame(&.{});
    try testing.expect(b.flipPending());
    fake.queueFlipEvent(41, Drm2d.flip_cookie);
    try d.readEvents();
    try b.waitFlip();
    try testing.expect(!b.flipPending());
    try b.setDpms(.off);
    try testing.expectEqual(DpmsState.off, d.dpmsState());
    try testing.expect(b.supportsHwCursor());
    try b.setCursor(null, 0, 0);
    try testing.expectEqual(@as(u32, 0), fake.cursor_calls.items[fake.cursor_calls.items.len - 1].handle);
}

test "gpus: policy filter matches kmscon seat_gpu_is_ignored" {
    // all keeps everything; primary only primary; aux primary-or-aux.
    try testing.expect(!gpuIgnored(false, false, .all));
    try testing.expect(!gpuIgnored(true, false, .all));
    try testing.expect(!gpuIgnored(false, true, .all));
    try testing.expect(gpuIgnored(false, false, .primary));
    try testing.expect(!gpuIgnored(true, false, .primary));
    try testing.expect(gpuIgnored(false, true, .primary));
    // The asymmetry: an unflagged card is kept by all but dropped by aux.
    try testing.expect(gpuIgnored(false, false, .aux));
    try testing.expect(!gpuIgnored(true, false, .aux));
    try testing.expect(!gpuIgnored(false, true, .aux));
    try testing.expect(!gpuIgnored(true, true, .aux));
}

test "gpus: selectGpus filters in order into the caller buffer" {
    const cands = [_]GpuCandidate{
        .{ .path = "/dev/dri/card0", .name = "card0", .primary = true },
        .{ .path = "/dev/dri/card1", .name = "card1", .aux = true },
        .{ .path = "/dev/dri/card2", .name = "card2" }, // unflagged
    };
    var out: [3]GpuCandidate = undefined;
    try testing.expectEqual(@as(usize, 3), selectGpus(&cands, .all, &out).len);
    const primary = selectGpus(&cands, .primary, &out);
    try testing.expectEqual(@as(usize, 1), primary.len);
    try testing.expectEqualStrings("card0", primary[0].name);
    const aux = selectGpus(&cands, .aux, &out);
    try testing.expectEqual(@as(usize, 2), aux.len);
    try testing.expectEqualStrings("card0", aux[0].name);
    try testing.expectEqualStrings("card1", aux[1].name);
}

test "gpus: isCardName accepts cardN, rejects renderDN and junk" {
    try testing.expect(isCardName("card0"));
    try testing.expect(isCardName("card12"));
    try testing.expect(!isCardName("renderD128"));
    try testing.expect(!isCardName("card"));
    try testing.expect(!isCardName("cardX"));
    try testing.expect(!isCardName("controlD64"));
}

test "mode: use-original-mode keeps the bound current mode" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    // The CRTC is currently driven at 1024x768 (fake_mode_1024, index 0).
    fake.crtc_current_mode = fake_mode_1024;
    const d = try Drm2d.init(a, "/dev/dri/card0", fake.ops());
    defer d.deinit();
    // HDMI-A-1 (index 1) current mode recovered from its bound CRTC.
    try testing.expectEqual(@as(?usize, 0), d.infos[1].current_mode);
    // use-original-mode selects it over the preferred 1920x1080 (index 1).
    try testing.expectEqual(@as(?usize, 0), try d.selectModeIndex(1, null, true));
    // Without use-original-mode the preferred mode wins.
    try testing.expectEqual(@as(?usize, 1), try d.selectModeIndex(1, null, false));
}

test "mode: mode= spec selects by resolution and rate, else preferred" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try Drm2d.init(a, "/dev/dri/card0", fake.ops());
    defer d.deinit();
    // HDMI-A-1 modes: [1024x768@60, 1920x1080@60 (preferred)].
    const spec = video.ModeSpec.parse("1024x768").?;
    try testing.expectEqual(@as(?usize, 0), try d.selectModeIndex(1, spec, false));
    const spec2 = video.ModeSpec.parse("1920x1080@60").?;
    try testing.expectEqual(@as(?usize, 1), try d.selectModeIndex(1, spec2, false));
    // No match falls back to preferred.
    const miss = video.ModeSpec.parse("640x480").?;
    try testing.expectEqual(@as(?usize, 1), try d.selectModeIndex(1, miss, false));
    // Out-of-range connector: null.
    try testing.expectEqual(@as(?usize, null), try d.selectModeIndex(99, null, false));
}

test "cursor: supportsHwCursor false when no cursor plane exists" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    fake.cursor_plane_present = false; // caps still report 64x64
    const d = try setupActive(a, &fake);
    defer d.deinit();
    // Constraint #8: a 64x64 cap answer alone does not prove a plane.
    try testing.expect(!d.supportsHwCursor());
    var img = try Framebuffer.create(a, 8, 8, .argb8888, null);
    defer img.destroy(a);
    try testing.expectError(error.Unsupported, d.setCursor(&img, 0, 0));
}

test "cursor: soft-cursor force hides the plane and gates setCursor" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    defer d.deinit();
    try testing.expect(d.supportsHwCursor());
    var img = try Framebuffer.create(a, 8, 8, .argb8888, null);
    defer img.destroy(a);
    try d.setCursor(&img, 1, 2);
    try testing.expectEqual(@as(usize, 1), fake.cursor_calls.items.len);
    // Force software: hides the hw cursor (handle 0) and gates further sets.
    d.setSoftCursorForce(true);
    try testing.expect(!d.supportsHwCursor());
    try testing.expectEqual(@as(u32, 0), fake.cursor_calls.items[fake.cursor_calls.items.len - 1].handle);
    try testing.expectError(error.Unsupported, d.setCursor(&img, 3, 4));
    // Releasing the force restores the hardware cursor.
    d.setSoftCursorForce(false);
    try testing.expect(d.supportsHwCursor());
}

/// Fake hotplug monitor: an event queue behind HotplugOps.
const FakeHotplug = struct {
    allocator: Allocator,
    events: std.ArrayList(HotplugEvent) = .empty,
    fd_value: i32 = 42,
    closed: bool = false,

    fn deinit(self: *FakeHotplug) void {
        self.events.deinit(self.allocator);
    }

    fn ops(self: *FakeHotplug) HotplugOps {
        return .{ .ctx = self, .open = open, .close = close, .fd = fd, .next = next };
    }

    fn cast(ctx: ?*anyopaque) *FakeHotplug {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn open(ctx: ?*anyopaque) !*anyopaque {
        return ctx.?;
    }

    fn close(ctx: ?*anyopaque, _: *anyopaque) void {
        cast(ctx).closed = true;
    }

    fn fd(ctx: ?*anyopaque, _: *anyopaque) i32 {
        return cast(ctx).fd_value;
    }

    fn next(ctx: ?*anyopaque, _: *anyopaque) !?HotplugEvent {
        const self = cast(ctx);
        if (self.events.items.len == 0) return null;
        const ev = self.events.items[0];
        std.mem.copyForwards(HotplugEvent, self.events.items[0..], self.events.items[1..]);
        self.events.shrinkRetainingCapacity(self.events.items.len - 1);
        return ev;
    }
};

test "hotplug: monitor fd, drain events, idempotent enable, close on deinit" {
    const a = testing.allocator;
    var fake: FakeDrm = .{ .allocator = a };
    defer fake.deinit();
    const d = try setupActive(a, &fake);
    // Not enabled yet: no fd, poll is a no-op.
    try testing.expect(d.hotplugFd() == null);
    try testing.expectEqual(false, try d.pollHotplug());

    var hp: FakeHotplug = .{ .allocator = a };
    defer hp.deinit();
    try d.enableHotplug(hp.ops());
    try testing.expectEqual(@as(?i32, 42), d.hotplugFd());
    try testing.expectEqual(false, try d.pollHotplug());
    // Queue events: poll drains them all and reports true.
    try hp.events.append(a, .change);
    try hp.events.append(a, .add);
    try testing.expectEqual(true, try d.pollHotplug());
    try testing.expectEqual(@as(usize, 0), hp.events.items.len);
    // Idempotent: a second enable does not replace the monitor.
    try d.enableHotplug(hp.ops());
    try testing.expectEqual(@as(?i32, 42), d.hotplugFd());

    d.deinit();
    try testing.expect(hp.closed);
}
