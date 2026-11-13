//! src/video/fbdev.zig -- Linux fbdev video backend (ROADMAP M5.2, `no-drm`).
//!
//! This is the fallback backend used when KMS/DRM is unavailable or disabled
//! with `no-drm`: it drives `/dev/fb*` through the Linux framebuffer ioctls
//! instead of libdrm. It implements exactly the `video.Backend` vtable, so the
//! session manager and renderer above it cannot tell fbdev from drm2d.
//!
//! Design notes
//! ------------
//! * **One synthetic connector.** fbdev exposes a single scanout surface, so
//!   `connectors()` reports one always-connected connector named after the
//!   device node (`fb0` for `/dev/fb0`) whose only mode is the mode currently
//!   programmed into the device. `setMode` therefore succeeds only for
//!   (connector 0, mode 0), re-applying the current `fb_var_screeninfo`.
//! * **Double buffering by vertical pan.** At init the backend asks the
//!   driver for `yres_virtual = 2 * yres` via `FBIOPUT_VSCREENINFO`. When the
//!   driver accepts (and the second half is 64-byte aligned, as
//!   `framebuffer.Framebuffer` requires), `beginFrame` returns the half that
//!   is not currently scanned out and `endFrame` presents it with
//!   `FBIOPAN_DISPLAY` (`yoffset` 0 or `yres`), then swaps the halves. If the
//!   driver refuses the virtual-resolution bump, the backend degrades to a
//!   single buffer: `beginFrame` returns the visible buffer and `endFrame` is
//!   a no-op (the pixels are already in scanout memory).
//! * **No flip events.** fbdev panning is programmed synchronously-ish by the
//!   kernel and has no page-flip event. `flipPending()` is therefore always
//!   false and `waitFlip()` is a no-op: frames are not vblank-paced. The
//!   damage argument to `endFrame` is accepted but ignored, because the pan
//!   presents the whole back buffer; callers must keep the whole back buffer
//!   up to date (the backend cannot restrict presentation to damage rects).
//! * **Pixel format.** Only 32bpp truecolor with an XRGB8888-compatible
//!   channel layout (`red` at bit 16, `green` at 8, `blue` at 0, each 8 bits,
//!   msb_right = 0; alpha either absent or at bit 24) is supported and is
//!   exposed as `framebuffer.PixelFormat.xrgb8888`. 16bpp, pseudocolor and
//!   unusual layouts are rejected with a clear error rather than rendered
//!   incorrectly.
//! * **Hermetic tests.** Every syscall (`open`, `close`, `ioctl`, `mmap`,
//!   `munmap`) goes through the `Sys` function-table below. Production uses
//!   `Sys.real()`; tests inject a fake that records ioctl traffic and serves
//!   an in-memory framebuffer, so no `/dev/fb0` is required.
//!
//! The fbdev ABI structs and ioctl numbers are declared directly (rather than
//! via translate-c) because `linux/fb.h` is a stable UAPI header: the ioctls
//! are the plain constants 0x4600/0x4601/... (not `_IOWR`-encoded), and the
//! structs below are `extern` with the exact C layout. `test "fbdev ABI"`
//! pins the 64-bit sizes/offsets against linux/fb.h.

const std = @import("std");
const video = @import("../video.zig");
const framebuffer = @import("../framebuffer.zig");

pub const Framebuffer = framebuffer.Framebuffer;
pub const PixelFormat = framebuffer.PixelFormat;
pub const Damage = framebuffer.Damage;
pub const Mode = video.Mode;
pub const ConnectorInfo = video.ConnectorInfo;
pub const DpmsState = video.DpmsState;
pub const Backend = video.Backend;

/// Device opened when `init` is passed a null path.
pub const default_path = "/dev/fb0";

// ---------------------------------------------------------------------------
// linux/fb.h ABI: ioctl request numbers (plain constants, see fb.h:18-40).
// ---------------------------------------------------------------------------

pub const FBIOGET_VSCREENINFO: u32 = 0x4600;
pub const FBIOPUT_VSCREENINFO: u32 = 0x4601;
pub const FBIOGET_FSCREENINFO: u32 = 0x4602;
pub const FBIOPAN_DISPLAY: u32 = 0x4606;
pub const FBIOBLANK: u32 = 0x4611;

/// `fb_fix_screeninfo.type`
pub const FB_TYPE_PACKED_PIXELS: u32 = 0;
/// `fb_fix_screeninfo.visual`
pub const FB_VISUAL_TRUECOLOR: u32 = 2;
/// `fb_var_screeninfo.activate`
pub const FB_ACTIVATE_NOW: u32 = 0;
/// `fb_var_screeninfo.vmode` mask (non-zero means interlaced/double scan).
pub const FB_VMODE_MASK: u32 = 255;

/// `FBIOBLANK` argument levels (`fb.h` VESA-derived enum).
pub const FB_BLANK_UNBLANK: u32 = 0;
pub const FB_BLANK_NORMAL: u32 = 1;
pub const FB_BLANK_VSYNC_SUSPEND: u32 = 2;
pub const FB_BLANK_HSYNC_SUSPEND: u32 = 3;
pub const FB_BLANK_POWERDOWN: u32 = 4;

/// `struct fb_bitfield`: where one color/alpha component lives in a pixel.
pub const Bitfield = extern struct {
    /// Bit position of the least significant bit of the field.
    offset: u32 = 0,
    /// Width of the field in bits.
    length: u32 = 0,
    /// Non-zero when the field's msb is stored on the right.
    msb_right: u32 = 0,
};

/// `struct fb_var_screeninfo` (linux/fb.h:241). `usize` mirrors C's
/// `unsigned long` nowhere in this struct, so the layout is stable across
/// 32/64-bit: 160 bytes on the 64-bit ABI.
pub const VarScreeninfo = extern struct {
    xres: u32 = 0,
    yres: u32 = 0,
    xres_virtual: u32 = 0,
    yres_virtual: u32 = 0,
    xoffset: u32 = 0,
    yoffset: u32 = 0,
    bits_per_pixel: u32 = 0,
    grayscale: u32 = 0,
    red: Bitfield = .{},
    green: Bitfield = .{},
    blue: Bitfield = .{},
    transp: Bitfield = .{},
    nonstd: u32 = 0,
    activate: u32 = 0,
    /// Physical height in millimetres.
    height: u32 = 0,
    /// Physical width in millimetres.
    width: u32 = 0,
    accel_flags: u32 = 0,
    pixclock: u32 = 0,
    left_margin: u32 = 0,
    right_margin: u32 = 0,
    upper_margin: u32 = 0,
    lower_margin: u32 = 0,
    hsync_len: u32 = 0,
    vsync_len: u32 = 0,
    sync: u32 = 0,
    vmode: u32 = 0,
    rotate: u32 = 0,
    colorspace: u32 = 0,
    reserved: [4]u32 = @splat(0),
};

/// `struct fb_fix_screeninfo` (linux/fb.h:156). `smem_start` and `mmio_start`
/// are C `unsigned long`, hence `usize`.
pub const FixScreeninfo = extern struct {
    id: [16]u8 = @splat(0),
    smem_start: usize = 0,
    smem_len: u32 = 0,
    type: u32 = 0,
    type_aux: u32 = 0,
    visual: u32 = 0,
    xpanstep: u16 = 0,
    ypanstep: u16 = 0,
    ywrapstep: u16 = 0,
    line_length: u32 = 0,
    mmio_start: usize = 0,
    mmio_len: u32 = 0,
    accel: u32 = 0,
    capabilities: u16 = 0,
    reserved: [2]u16 = @splat(0),
};

comptime {
    // The ABI is fixed by linux/fb.h. Pin it on the 64-bit Linux targets
    // kmshaunt supports; 32-bit sizes differ only in the `usize` fields.
    if (@sizeOf(usize) == 8) {
        if (@sizeOf(VarScreeninfo) != 160) @compileError("fb_var_screeninfo ABI mismatch");
        if (@sizeOf(FixScreeninfo) != 80) @compileError("fb_fix_screeninfo ABI mismatch");
        if (@offsetOf(VarScreeninfo, "red") != 32) @compileError("fb_bitfield ABI mismatch");
        if (@offsetOf(VarScreeninfo, "transp") != 68) @compileError("fb_bitfield ABI mismatch");
        if (@offsetOf(FixScreeninfo, "line_length") != 48) @compileError("fb_fix ABI mismatch");
    }
}

// ---------------------------------------------------------------------------
// Injectable syscall layer.
// ---------------------------------------------------------------------------

/// Small function table for the five syscalls the backend needs. Production
/// code uses `Sys.real()`; tests pass an implementation with their own `ctx`.
///
/// `ioctl` takes the raw `usize` argument rather than a pointer because most
/// fbdev ioctls take a struct pointer while `FBIOBLANK` takes an integer
/// level; callers pass `@intFromPtr(&struct)` or the level itself.
pub const Sys = struct {
    ctx: ?*anyopaque = null,
    open: *const fn (ctx: ?*anyopaque, path: [*:0]const u8) anyerror!std.posix.fd_t,
    close: *const fn (ctx: ?*anyopaque, fd: std.posix.fd_t) void,
    ioctl: *const fn (ctx: ?*anyopaque, fd: std.posix.fd_t, request: u32, arg: usize) anyerror!void,
    mmap: *const fn (ctx: ?*anyopaque, fd: std.posix.fd_t, len: usize) anyerror![]align(std.heap.page_size_min) u8,
    munmap: *const fn (ctx: ?*anyopaque, mem: []align(std.heap.page_size_min) const u8) void,

    /// The real Linux implementation used in production.
    pub fn real() Sys {
        return .{
            .open = realOpen,
            .close = realClose,
            .ioctl = realIoctl,
            .mmap = realMmap,
            .munmap = realMunmap,
        };
    }

    fn realOpen(_: ?*anyopaque, path: [*:0]const u8) anyerror!std.posix.fd_t {
        return std.posix.openatZ(
            std.os.linux.AT.FDCWD,
            path,
            .{ .ACCMODE = .RDWR, .CLOEXEC = true },
            0,
        );
    }

    fn realClose(_: ?*anyopaque, fd: std.posix.fd_t) void {
        _ = std.os.linux.close(fd);
    }

    fn realIoctl(_: ?*anyopaque, fd: std.posix.fd_t, request: u32, arg: usize) anyerror!void {
        const rc = std.os.linux.ioctl(fd, request, arg);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .BADF => error.InvalidFileDescriptor,
            .FAULT => error.InvalidAddress,
            .INVAL => error.InvalidArgument,
            .NOTTY => error.Unsupported,
            .PERM, .ACCES => error.AccessDenied,
            .NOSYS, .OPNOTSUPP => error.Unsupported,
            else => error.IoctlFailed,
        };
    }

    fn realMmap(_: ?*anyopaque, fd: std.posix.fd_t, len: usize) anyerror![]align(std.heap.page_size_min) u8 {
        return std.posix.mmap(
            null,
            len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
    }

    fn realMunmap(_: ?*anyopaque, mem: []align(std.heap.page_size_min) const u8) void {
        std.posix.munmap(mem);
    }
};

// ---------------------------------------------------------------------------
// The backend.
// ---------------------------------------------------------------------------

/// The fbdev backend. Holds the mapped scanout memory, the (at most two)
/// framebuffer halves, and heap-owned connector/mode metadata. Obtain one
/// with `init`, then hand `backend()` to the rest of the application.
pub const Fbdev = struct {
    allocator: std.mem.Allocator,
    sys: Sys,
    fd: std.posix.fd_t,

    /// Last `fb_var_screeninfo` read from (or written to) the driver. Kept in
    /// sync with the current x/y offsets so `setMode` re-applies the live mode.
    var_info: VarScreeninfo,
    fix_info: FixScreeninfo,

    mapping: []align(std.heap.page_size_min) u8,

    /// Half 0 starting at mmap offset 0 (the only buffer in single-buffer mode).
    buf_a: Framebuffer,
    /// Half 1 starting at `line_length * yres`, or null in single-buffer mode.
    buf_b: ?Framebuffer,
    /// Whether `buf_b` (the high half) is currently scanned out. Only
    /// meaningful when `buf_b` is non-null.
    scanout_high: bool,

    dpms: DpmsState,

    /// Heap storage returned by `connectors()`; owns `name` by reference.
    modes: []Mode,
    connectors: []ConnectorInfo,
    name: []u8,

    /// Human-readable state, useful for diagnostics/tests.
    pub fn doubleBuffered(self: *const Fbdev) bool {
        return self.buf_b != null;
    }

    /// Initialize the backend for `path` (null selects `default_path`) using
    /// `sys` for all syscalls. On success the device is mapped and its
    /// current mode is reported through `connectors()`.
    ///
    /// Errors (beyond the injected `Sys` errors):
    /// * `UnsupportedDepth` -- not 32 bits per pixel.
    /// * `UnsupportedVisual` -- not `FB_VISUAL_TRUECOLOR` / not packed pixels.
    /// * `UnsupportedPixelFormat` -- grayscale, FOURCC or non-standard layout.
    /// * `UnsupportedPixelLayout` -- channels are not XRGB8888-compatible.
    /// * `UnsupportedVideoMode` -- interlaced/double-scan timing.
    /// * `InvalidFramebuffer` -- zero/overflowing geometry or `smem_len` too
    ///   small for even one frame.
    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8, sys: Sys) anyerror!Fbdev {
        comptime {
            if (std.heap.page_size_min < 64) {
                @compileError("fbdev requires mmap alignment of at least 64 bytes");
            }
        }

        const dev_path = path orelse default_path;
        const zpath = try allocator.allocSentinel(u8, dev_path.len, 0);
        defer allocator.free(zpath);
        @memcpy(zpath, dev_path);

        const fd = try sys.open(sys.ctx, zpath);
        errdefer sys.close(sys.ctx, fd);

        var var_info: VarScreeninfo = std.mem.zeroes(VarScreeninfo);
        try sys.ioctl(sys.ctx, fd, FBIOGET_VSCREENINFO, @intFromPtr(&var_info));
        var fix_info: FixScreeninfo = std.mem.zeroes(FixScreeninfo);
        try sys.ioctl(sys.ctx, fd, FBIOGET_FSCREENINFO, @intFromPtr(&fix_info));
        try validate(&var_info, &fix_info);

        var geom = geometry(&var_info, &fix_info) orelse return error.InvalidFramebuffer;
        if (fix_info.smem_len != 0 and geom.single_len > fix_info.smem_len) {
            return error.InvalidFramebuffer;
        }

        // Try to get a second half. The driver may grow its allocation when
        // the virtual resolution changes (drmfb does), so the pre-PUT
        // smem_len is not a reliable rejection criterion; we PUT first and
        // verify afterwards.
        var want_double = geom.single_len % 64 == 0;
        if (want_double and 2 * @as(u64, var_info.yres) > std.math.maxInt(u32)) {
            want_double = false;
        }

        if (want_double) {
            const virtual_ready =
                @as(u64, var_info.yres_virtual) >= 2 * @as(u64, var_info.yres) and
                var_info.xoffset == 0 and
                var_info.yoffset == 0;

            if (!virtual_ready) {
                var req = var_info;
                req.xoffset = 0;
                req.yoffset = 0;
                req.yres_virtual = @intCast(@max(
                    @as(u64, req.yres_virtual),
                    2 * @as(u64, req.yres),
                ));
                req.activate = FB_ACTIVATE_NOW;

                if (sys.ioctl(sys.ctx, fd, FBIOPUT_VSCREENINFO, @intFromPtr(&req))) |_| {
                    var_info = req;
                    // The driver may clamp/round whatever it accepted, and
                    // line_length/smem_len can change with the virtual size.
                    try sys.ioctl(sys.ctx, fd, FBIOGET_VSCREENINFO, @intFromPtr(&var_info));
                    try sys.ioctl(sys.ctx, fd, FBIOGET_FSCREENINFO, @intFromPtr(&fix_info));
                    try validate(&var_info, &fix_info);
                    geom = geometry(&var_info, &fix_info) orelse return error.InvalidFramebuffer;
                } else |_| {
                    // Driver refused the virtual-resolution bump: fall back to
                    // a single buffer. A failed fb_set_var leaves the mode
                    // untouched, so the original var/fix remain valid.
                    want_double = false;
                }
            }

            if (want_double) {
                const smem_ok = fix_info.smem_len == 0 or
                    @as(u64, fix_info.smem_len) >= geom.double_len;
                want_double =
                    @as(u64, var_info.yres_virtual) >= 2 * @as(u64, var_info.yres) and
                    var_info.xoffset == 0 and
                    var_info.yoffset == 0 and
                    geom.single_len % 64 == 0 and
                    geom.double_len <= std.math.maxInt(usize) and
                    smem_ok;
            }
        }

        if (!want_double and geom.single_len > std.math.maxInt(usize)) {
            return error.InvalidFramebuffer;
        }

        const map_len: usize = @intCast(if (want_double) geom.double_len else geom.single_len);
        const mapping = try sys.mmap(sys.ctx, fd, map_len);
        errdefer sys.munmap(sys.ctx, mapping);

        // Device name and connector/mode metadata are heap-allocated so the
        // slices stay valid when the Fbdev value is moved by the caller.
        const base = if (std.mem.lastIndexOfScalar(u8, dev_path, '/')) |idx|
            dev_path[idx + 1 ..]
        else
            dev_path;
        const conn_name = try allocator.dupe(u8, if (base.len == 0) "fb0" else base);
        errdefer allocator.free(conn_name);

        const modes = try allocator.alloc(Mode, 1);
        errdefer allocator.free(modes);
        modes[0] = modeFromVar(&var_info);

        const connectors = try allocator.alloc(ConnectorInfo, 1);
        errdefer allocator.free(connectors);
        connectors[0] = .{
            .name = conn_name,
            .card_name = conn_name,
            .connected = true,
            .modes = modes,
            .preferred_mode = 0,
            .current_mode = 0,
        };

        // mmap is page-aligned, hence at least 64-byte aligned (asserted
        // above). The second half is only used when its offset is 64-aligned.
        const raw: [*]u8 = mapping.ptr;
        const pixels: [*]align(64) u8 = @alignCast(raw);
        const single_mem = pixels[0..@intCast(geom.single_len)];

        var buf_b: ?Framebuffer = null;
        if (want_double) {
            const off: usize = @intCast(geom.single_len);
            // off % 64 == 0 was checked above, so the slice stays 64-aligned.
            const high_mem: []align(64) u8 = @alignCast(
                pixels[off..][0..@intCast(geom.single_len)],
            );
            buf_b = .{
                .mem = high_mem,
                .width = var_info.xres,
                .height = var_info.yres,
                .pitch = fix_info.line_length,
                .format = .xrgb8888,
            };
        }

        return .{
            .allocator = allocator,
            .sys = sys,
            .fd = fd,
            .var_info = var_info,
            .fix_info = fix_info,
            .mapping = mapping,
            .buf_a = .{
                .mem = single_mem,
                .width = var_info.xres,
                .height = var_info.yres,
                .pitch = fix_info.line_length,
                .format = .xrgb8888,
            },
            .buf_b = buf_b,
            .scanout_high = false,
            .dpms = .on,
            .modes = modes,
            .connectors = connectors,
            .name = conn_name,
        };
    }

    /// `init` with the real Linux syscall implementation.
    pub fn initReal(allocator: std.mem.Allocator, path: ?[]const u8) anyerror!Fbdev {
        return init(allocator, path, Sys.real());
    }

    /// Release the mapping, close the device and free connector metadata.
    pub fn deinit(self: *Fbdev) void {
        self.sys.munmap(self.sys.ctx, self.mapping);
        self.sys.close(self.sys.ctx, self.fd);
        self.allocator.free(self.name);
        self.allocator.free(self.modes);
        self.allocator.free(self.connectors);
    }

    /// The `video.Backend` vtable view of this backend.
    pub fn backend(self: *Fbdev) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn ioctl(self: *Fbdev, request: u32, arg: usize) anyerror!void {
        return self.sys.ioctl(self.sys.ctx, self.fd, request, arg);
    }

    const vtable = Backend.VTable{
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

    fn cast(ptr: *anyopaque) *Fbdev {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).deinit();
    }

    fn vtConnectors(ptr: *anyopaque) anyerror![]const ConnectorInfo {
        const self = cast(ptr);
        // fbdev has no hotplug and no mode enumeration: the only connector is
        // the device node itself, already in its current mode.
        self.connectors[0].current_mode = 0;
        self.connectors[0].preferred_mode = 0;
        self.modes[0] = modeFromVar(&self.var_info);
        return self.connectors;
    }

    fn vtSetMode(ptr: *anyopaque, connector_idx: usize, mode_idx: usize) anyerror!void {
        const self = cast(ptr);
        if (connector_idx >= self.connectors.len or mode_idx >= self.modes.len) {
            return error.Unsupported;
        }
        if (connector_idx != 0 or mode_idx != 0) return error.Unsupported;

        // The only enumerable mode is the one already programmed: re-apply it
        // via FBIOPUT_VSCREENINFO with the live offsets/yres_virtual.
        self.var_info.activate = FB_ACTIVATE_NOW;
        try self.ioctl(FBIOPUT_VSCREENINFO, @intFromPtr(&self.var_info));
        self.modes[0] = modeFromVar(&self.var_info);
        self.connectors[0].current_mode = 0;
    }

    fn vtBeginFrame(ptr: *anyopaque) anyerror!*Framebuffer {
        const self = cast(ptr);
        if (self.buf_b) |*high| {
            return if (self.scanout_high) &self.buf_a else high;
        }
        return &self.buf_a;
    }

    fn vtEndFrame(ptr: *anyopaque, damage: []const Damage) anyerror!void {
        const self = cast(ptr);
        // fbdev cannot restrict scanout to damage rectangles: the pan shows
        // the entire back buffer. `damage` is therefore intentionally unused.
        _ = damage;

        if (self.buf_b == null) {
            // Single buffer: drawing already went straight to scanout memory.
            return;
        }

        const target_high = !self.scanout_high;
        const new_yoffset: u32 = if (target_high) self.var_info.yres else 0;
        const old_yoffset = self.var_info.yoffset;
        self.var_info.xoffset = 0;
        self.var_info.yoffset = new_yoffset;
        self.ioctl(FBIOPAN_DISPLAY, @intFromPtr(&self.var_info)) catch |err| {
            // Leave the swap undone so the next beginFrame retries the same
            // back buffer.
            self.var_info.yoffset = old_yoffset;
            return err;
        };
        self.scanout_high = target_high;
    }

    fn vtFlipPending(ptr: *anyopaque) bool {
        _ = ptr;
        // fbdev has no page-flip event: FBIOPAN_DISPLAY is programmed by the
        // kernel and there is nothing to wait for.
        return false;
    }

    fn vtWaitFlip(ptr: *anyopaque) anyerror!void {
        _ = ptr;
        // No pending flip by construction (see vtFlipPending).
    }

    fn vtSetDpms(ptr: *anyopaque, state: DpmsState) anyerror!void {
        const self = cast(ptr);
        const level: u32 = switch (state) {
            .on => FB_BLANK_UNBLANK,
            .standby => FB_BLANK_NORMAL,
            .suspend_ => FB_BLANK_VSYNC_SUSPEND,
            .off => FB_BLANK_POWERDOWN,
        };
        try self.ioctl(FBIOBLANK, level);
        self.dpms = state;
    }

    fn vtSetCursor(ptr: *anyopaque, img: ?*Framebuffer, x: i32, y: i32) anyerror!void {
        _ = ptr;
        _ = img;
        _ = x;
        _ = y;
        // No cursor plane in fbdev; the renderer must composite a software
        // cursor (supportsHwCursor() == false).
        return error.Unsupported;
    }

    fn vtSupportsHwCursor(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }
};

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

const Geometry = struct {
    /// Bytes for one full frame (`line_length * yres`).
    single_len: u64,
    /// Bytes for both halves (`single_len * 2`).
    double_len: u64,
};

fn geometry(v: *const VarScreeninfo, f: *const FixScreeninfo) ?Geometry {
    if (f.line_length == 0 or v.yres == 0) return null;
    const single = @as(u64, f.line_length) * @as(u64, v.yres);
    if (single == 0) return null;
    if (single > std.math.maxInt(u64) / 2) return null;
    return .{ .single_len = single, .double_len = single * 2 };
}

fn channelOk(b: Bitfield, offset: u32) bool {
    return b.offset == offset and b.length == 8 and b.msb_right == 0;
}

/// Reject any mode this backend cannot render correctly. Called both before
/// and after the virtual-resolution PUT.
fn validate(v: *const VarScreeninfo, f: *const FixScreeninfo) anyerror!void {
    // Report the format rejections first: they explain why an otherwise
    // plausible-looking mode is unusable (e.g. 16bpp has a smaller
    // line_length than the 32bpp check below would accept).
    if (v.bits_per_pixel != 32) return error.UnsupportedDepth;
    if (f.visual != FB_VISUAL_TRUECOLOR) return error.UnsupportedVisual;
    if (f.type != FB_TYPE_PACKED_PIXELS) return error.UnsupportedVisual;
    if (v.grayscale != 0 or v.nonstd != 0) return error.UnsupportedPixelFormat;
    if (v.vmode & FB_VMODE_MASK != 0) return error.UnsupportedVideoMode;

    if (v.xres == 0 or v.yres == 0) return error.InvalidFramebuffer;
    if (v.xres_virtual < v.xres or v.yres_virtual < v.yres) return error.InvalidFramebuffer;
    if (f.line_length == 0) return error.InvalidFramebuffer;
    if (@as(u64, f.line_length) < @as(u64, v.xres) * 4) return error.InvalidFramebuffer;

    // XRGB8888: blue at bits 0..7, green 8..15, red 16..23. Accept either no
    // alpha channel (transp.length == 0, high byte ignored) or an alpha
    // channel at 24..31 (which xrgb8888 drawing simply leaves untouched).
    if (!channelOk(v.red, 16) or !channelOk(v.green, 8) or !channelOk(v.blue, 0)) {
        return error.UnsupportedPixelLayout;
    }
    if (!(v.transp.length == 0 or channelOk(v.transp, 24))) {
        return error.UnsupportedPixelLayout;
    }
}

/// Build the single reported mode from the live `fb_var_screeninfo`.
fn modeFromVar(v: *const VarScreeninfo) Mode {
    return .{
        .width_px = v.xres,
        .height_px = v.yres,
        .refresh_mhz = refreshMilliHz(v),
        .width_mm = v.width,
        .height_mm = v.height,
    };
}

/// Derive the refresh rate in millihertz from the fb timing fields:
/// pixel clock (picoseconds) and total horizontal/vertical pixel counts
/// (including blanking and sync lengths). Returns 60 Hz when the driver does
/// not report a timing (pixclock == 0), matching kmscon's fallback.
fn refreshMilliHz(v: *const VarScreeninfo) u32 {
    if (v.pixclock == 0) return 60_000;
    const htotal = @as(u64, v.xres) + v.left_margin + v.right_margin + v.hsync_len;
    const vtotal = @as(u64, v.yres) + v.upper_margin + v.lower_margin + v.vsync_len;
    const den: u128 = @as(u128, v.pixclock) * @as(u128, htotal) * @as(u128, vtotal);
    if (den == 0) return 60_000;
    // 1e12 ps/s * 1000 mHz/Hz / (ps per pixel * pixels per frame).
    const mhz = @as(u128, 1_000_000_000_000_000) / den;
    if (mhz == 0) return 60_000;
    return @intCast(@min(mhz, @as(u128, std.math.maxInt(u32))));
}

// ---------------------------------------------------------------------------
// Tests: hermetic fake Sys (no /dev/fb0 needed).
// ---------------------------------------------------------------------------
//
// Note for the test runner: fbdev.zig lives in src/video/, so the canonical
// command is `zig test src/test_fbdev.zig` (a src-rooted module), not
// `zig test src/video/fbdev.zig` (its module root is src/video/ and the
// canonical `../video.zig` import escapes it).

const testing = std.testing;

const FakeSys = struct {
    allocator: std.mem.Allocator,
    var_info: VarScreeninfo,
    fix_info: FixScreeninfo,
    fd: std.posix.fd_t = 91,

    opened: bool = false,
    closed: bool = false,
    mapping: ?[]align(std.heap.page_size_min) u8 = null,
    mmap_len: usize = 0,
    munmap_len: usize = 0,

    fail_put: bool = false,
    fail_pan: bool = false,

    calls: std.ArrayList(Call) = .empty,

    const Kind = enum {
        open,
        close,
        get_var,
        put_var,
        get_fix,
        pan,
        blank,
        mmap,
        munmap,
    };

    const Call = struct {
        kind: Kind,
        /// Blank level, mmap/munmap length, etc.
        arg: usize = 0,
        yoffset: u32 = 0,
        yres_virtual: u32 = 0,
        line_length: u32 = 0,
        /// Owned copy of the path passed to open.
        path: ?[]u8 = null,
    };

    fn init(allocator: std.mem.Allocator, var_info: VarScreeninfo, fix_info: FixScreeninfo) FakeSys {
        return .{
            .allocator = allocator,
            .var_info = var_info,
            .fix_info = fix_info,
        };
    }

    fn deinit(self: *FakeSys) void {
        for (self.calls.items) |call| {
            if (call.path) |p| self.allocator.free(p);
        }
        self.calls.deinit(self.allocator);
        if (self.mapping) |m| {
            self.allocator.free(m);
            self.mapping = null;
        }
    }

    fn sys(self: *FakeSys) Sys {
        return .{
            .ctx = self,
            .open = fakeOpen,
            .close = fakeClose,
            .ioctl = fakeIoctl,
            .mmap = fakeMmap,
            .munmap = fakeMunmap,
        };
    }

    fn record(self: *FakeSys, call: Call) void {
        self.calls.append(self.allocator, call) catch @panic("fake sys: OOM recording call");
    }

    fn callCount(self: *const FakeSys, kind: Kind) usize {
        var n: usize = 0;
        for (self.calls.items) |call| {
            if (call.kind == kind) n += 1;
        }
        return n;
    }

    fn expectCall(self: *const FakeSys, index: usize, kind: Kind) !void {
        try testing.expect(index < self.calls.items.len);
        try testing.expectEqual(kind, self.calls.items[index].kind);
    }

    fn last(self: *const FakeSys, kind: Kind) ?Call {
        var i = self.calls.items.len;
        while (i > 0) {
            i -= 1;
            if (self.calls.items[i].kind == kind) return self.calls.items[i];
        }
        return null;
    }

    fn ctxOf(ctx: ?*anyopaque) *FakeSys {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn fakeOpen(ctx: ?*anyopaque, path: [*:0]const u8) anyerror!std.posix.fd_t {
        const self = ctxOf(ctx);
        const copy = try self.allocator.dupe(u8, std.mem.span(path));
        errdefer self.allocator.free(copy);
        self.record(.{ .kind = .open, .path = copy });
        self.opened = true;
        return self.fd;
    }

    fn fakeClose(ctx: ?*anyopaque, fd: std.posix.fd_t) void {
        const self = ctxOf(ctx);
        std.debug.assert(fd == self.fd);
        self.closed = true;
        self.record(.{ .kind = .close });
    }

    fn fakeIoctl(
        ctx: ?*anyopaque,
        fd: std.posix.fd_t,
        request: u32,
        arg: usize,
    ) anyerror!void {
        const self = ctxOf(ctx);
        if (fd != self.fd) return error.InvalidFileDescriptor;

        switch (request) {
            FBIOGET_VSCREENINFO => {
                const out: *VarScreeninfo = @ptrFromInt(arg);
                out.* = self.var_info;
                self.record(.{ .kind = .get_var });
            },
            FBIOPUT_VSCREENINFO => {
                const in: *VarScreeninfo = @ptrFromInt(arg);
                self.record(.{
                    .kind = .put_var,
                    .yoffset = in.yoffset,
                    .yres_virtual = in.yres_virtual,
                    .line_length = self.fix_info.line_length,
                });
                if (self.fail_put) return error.IoctlFailed;
                // Mirror the kernel ABI: the accepted var is copied back.
                self.var_info = in.*;
            },
            FBIOGET_FSCREENINFO => {
                const out: *FixScreeninfo = @ptrFromInt(arg);
                out.* = self.fix_info;
                self.record(.{ .kind = .get_fix, .line_length = self.fix_info.line_length });
            },
            FBIOPAN_DISPLAY => {
                const in: *VarScreeninfo = @ptrFromInt(arg);
                self.record(.{
                    .kind = .pan,
                    .yoffset = in.yoffset,
                    .yres_virtual = in.yres_virtual,
                });
                if (self.fail_pan) return error.IoctlFailed;
                self.var_info.yoffset = in.yoffset;
            },
            FBIOBLANK => {
                self.record(.{ .kind = .blank, .arg = arg });
            },
            else => return error.Unsupported,
        }
    }

    fn fakeMmap(
        ctx: ?*anyopaque,
        fd: std.posix.fd_t,
        len: usize,
    ) anyerror![]align(std.heap.page_size_min) u8 {
        const self = ctxOf(ctx);
        std.debug.assert(fd == self.fd);
        const mem = try self.allocator.alignedAlloc(
            u8,
            .fromByteUnits(std.heap.page_size_min),
            len,
        );
        @memset(mem, 0);
        self.mapping = mem;
        self.mmap_len = len;
        self.record(.{ .kind = .mmap, .arg = len });
        return mem;
    }

    fn fakeMunmap(
        ctx: ?*anyopaque,
        mem: []align(std.heap.page_size_min) const u8,
    ) void {
        const self = ctxOf(ctx);
        self.munmap_len = mem.len;
        self.record(.{ .kind = .munmap, .arg = mem.len });
        self.allocator.free(@constCast(mem));
        self.mapping = null;
    }
};

fn testVar() VarScreeninfo {
    var v = std.mem.zeroes(VarScreeninfo);
    v.xres = 640;
    v.yres = 480;
    v.xres_virtual = 640;
    v.yres_virtual = 480;
    v.bits_per_pixel = 32;
    v.red = .{ .offset = 16, .length = 8 };
    v.green = .{ .offset = 8, .length = 8 };
    v.blue = .{ .offset = 0, .length = 8 };
    v.transp = .{ .offset = 24, .length = 8 };
    v.width = 170;
    v.height = 128;
    v.pixclock = 39_722; // ~25.175 MHz pixel clock
    v.left_margin = 48;
    v.right_margin = 16;
    v.hsync_len = 96;
    v.upper_margin = 33;
    v.lower_margin = 10;
    v.vsync_len = 2;
    return v;
}

fn testFix(line_length: u32, smem_len: u32) FixScreeninfo {
    var f = std.mem.zeroes(FixScreeninfo);
    const id = "fakefb";
    @memcpy(f.id[0..id.len], id);
    f.smem_len = smem_len;
    f.type = FB_TYPE_PACKED_PIXELS;
    f.visual = FB_VISUAL_TRUECOLOR;
    f.line_length = line_length;
    return f;
}

test "fbdev ABI: struct sizes and offsets match linux/fb.h" {
    if (@sizeOf(usize) == 8) {
        try testing.expectEqual(@as(usize, 160), @sizeOf(VarScreeninfo));
        try testing.expectEqual(@as(usize, 80), @sizeOf(FixScreeninfo));
        try testing.expectEqual(@as(usize, 32), @offsetOf(VarScreeninfo, "red"));
        try testing.expectEqual(@as(usize, 68), @offsetOf(VarScreeninfo, "transp"));
        try testing.expectEqual(@as(usize, 48), @offsetOf(FixScreeninfo, "line_length"));
        try testing.expectEqual(@as(usize, 72), @offsetOf(FixScreeninfo, "capabilities"));
    }
}

test "init parses var/fix, requests double buffering and reports one connector" {
    var fake = FakeSys.init(testing.allocator, testVar(), testFix(2560, 2560 * 960));
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, "/dev/fb0", fake.sys());
    defer dev.deinit();

    // Call sequence: open, GET var, GET fix, PUT var (=2*yres), GET var,
    // GET fix, mmap. The second GET round-trip reflects what the driver
    // actually accepted.
    try fake.expectCall(0, .open);
    try fake.expectCall(1, .get_var);
    try fake.expectCall(2, .get_fix);
    try fake.expectCall(3, .put_var);
    try fake.expectCall(4, .get_var);
    try fake.expectCall(5, .get_fix);
    try fake.expectCall(6, .mmap);
    try testing.expectEqualStrings("/dev/fb0", fake.calls.items[0].path.?);

    const put = fake.calls.items[3];
    try testing.expectEqual(@as(u32, 960), put.yres_virtual);
    try testing.expectEqual(@as(u32, 0), put.yoffset);

    try testing.expect(dev.doubleBuffered());
    try testing.expectEqual(@as(u32, 640), dev.buf_a.width);
    try testing.expectEqual(@as(u32, 480), dev.buf_a.height);
    try testing.expectEqual(@as(u32, 2560), dev.buf_a.pitch);
    try testing.expectEqual(PixelFormat.xrgb8888, dev.buf_a.format);
    try testing.expectEqual(@as(usize, 2560 * 480), dev.buf_a.mem.len);

    const high = dev.buf_b.?;
    try testing.expectEqual(@as(usize, 2560 * 480), high.mem.len);
    try testing.expectEqual(
        @intFromPtr(dev.buf_a.mem.ptr) + 2560 * 480,
        @intFromPtr(high.mem.ptr),
    );
    try testing.expectEqual(@as(usize, 2560 * 960), fake.mmap_len);

    const conns = try dev.backend().connectors();
    try testing.expectEqual(@as(usize, 1), conns.len);
    try testing.expectEqualStrings("fb0", conns[0].name);
    try testing.expectEqualStrings("fb0", conns[0].card_name);
    try testing.expect(conns[0].connected);
    try testing.expectEqual(@as(?usize, 0), conns[0].preferred_mode);
    try testing.expectEqual(@as(?usize, 0), conns[0].current_mode);
    try testing.expectEqual(@as(usize, 1), conns[0].modes.len);
    try testing.expectEqual(@as(u32, 640), conns[0].modes[0].width_px);
    try testing.expectEqual(@as(u32, 480), conns[0].modes[0].height_px);
    try testing.expectEqual(@as(u32, 170), conns[0].modes[0].width_mm);
    try testing.expectEqual(@as(u32, 128), conns[0].modes[0].height_mm);
    // 25.175 MHz / (800 * 525) ~= 59.94 Hz.
    try testing.expect(conns[0].modes[0].refresh_mhz > 59_000);
    try testing.expect(conns[0].modes[0].refresh_mhz < 61_000);
}

test "init with null path opens /dev/fb0 and derives the connector name" {
    var fake = FakeSys.init(testing.allocator, testVar(), testFix(2560, 2560 * 960));
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, null, fake.sys());
    defer dev.deinit();

    try testing.expectEqualStrings("/dev/fb0", fake.calls.items[0].path.?);
    const conns = try dev.backend().connectors();
    try testing.expectEqualStrings("fb0", conns[0].name);

    var fake1 = FakeSys.init(testing.allocator, testVar(), testFix(2560, 2560 * 960));
    defer fake1.deinit();
    var dev1 = try Fbdev.init(testing.allocator, "/dev/fb1", fake1.sys());
    defer dev1.deinit();
    const conns1 = try dev1.backend().connectors();
    try testing.expectEqualStrings("fb1", conns1[0].name);
}

test "beginFrame/endFrame pan between halves and alternate" {
    var fake = FakeSys.init(testing.allocator, testVar(), testFix(2560, 2560 * 960));
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, "/dev/fb0", fake.sys());
    defer dev.deinit();

    const be = dev.backend();

    // First frame goes to the high half (scanout starts at the low half).
    const first = try be.beginFrame();
    try testing.expectEqual(@intFromPtr(dev.buf_b.?.mem.ptr), @intFromPtr(first.mem.ptr));
    first.set(0, 0, 0x00123456);
    const first_off = @intFromPtr(first.mem.ptr) - @intFromPtr(dev.mapping.ptr);
    try testing.expectEqual(@as(usize, 2560 * 480), first_off);

    // Damage is ignored, but a non-empty rect still pans.
    try be.endFrame(&.{.{ .x = 1, .y = 2, .w = 3, .h = 4 }});
    {
        const pan = fake.last(.pan).?;
        try testing.expectEqual(@as(u32, 480), pan.yoffset);
        try testing.expectEqual(@as(u32, 960), pan.yres_virtual);
        try testing.expectEqual(@as(u32, 480), dev.var_info.yoffset);
    }
    try testing.expect(!be.flipPending());
    try be.waitFlip();

    // Second frame goes to the low half, pan back to yoffset 0.
    const second = try be.beginFrame();
    try testing.expectEqual(@intFromPtr(dev.buf_a.mem.ptr), @intFromPtr(second.mem.ptr));
    try be.endFrame(&.{});
    {
        const pan = fake.last(.pan).?;
        try testing.expectEqual(@as(u32, 0), pan.yoffset);
        try testing.expectEqual(@as(u32, 0), dev.var_info.yoffset);
    }

    // Alternation repeats.
    const third = try be.beginFrame();
    try testing.expectEqual(@intFromPtr(dev.buf_b.?.mem.ptr), @intFromPtr(third.mem.ptr));
    try be.endFrame(&.{});
    try testing.expectEqual(@as(u32, 480), fake.last(.pan).?.yoffset);
    try testing.expectEqual(@as(usize, 3), fake.callCount(.pan));
}

test "single buffer when the driver refuses yres_virtual = 2*yres" {
    var fake = FakeSys.init(testing.allocator, testVar(), testFix(2560, 2560 * 480));
    fake.fail_put = true;
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, "/dev/fb0", fake.sys());
    defer dev.deinit();

    try testing.expect(!dev.doubleBuffered());
    try testing.expect(dev.buf_b == null);
    try fake.expectCall(3, .put_var); // attempt failed...
    try testing.expectEqual(@as(usize, 1), fake.callCount(.get_var)); // ...no re-GET

    const be = dev.backend();
    const frame = try be.beginFrame();
    try testing.expectEqual(@intFromPtr(dev.buf_a.mem.ptr), @intFromPtr(frame.mem.ptr));
    frame.set(1, 1, 0x00abcdef);
    try be.endFrame(&.{.{ .x = 1, .y = 1, .w = 1, .h = 1 }});
    try testing.expectEqual(@as(usize, 0), fake.callCount(.pan));
    try testing.expectEqual(@as(usize, 2560 * 480), fake.mmap_len);
    try testing.expect(!be.flipPending());
}

test "already double-buffered device skips FBIOPUT_VSCREENINFO" {
    var v = testVar();
    v.yres_virtual = 960;
    var fake = FakeSys.init(testing.allocator, v, testFix(2560, 2560 * 960));
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, "/dev/fb0", fake.sys());
    defer dev.deinit();

    try testing.expect(dev.doubleBuffered());
    try testing.expectEqual(@as(usize, 0), fake.callCount(.put_var));
    try fake.expectCall(0, .open);
    try fake.expectCall(1, .get_var);
    try fake.expectCall(2, .get_fix);
    try fake.expectCall(3, .mmap);
}

test "unaligned second half falls back to a single buffer without a PUT" {
    var v = testVar();
    v.yres = 100;
    v.yres_virtual = 100;
    const line_length: u32 = 2564; // 640*4 + 4; line_length*yres is not 64-aligned
    try testing.expect((@as(u64, line_length) * 100) % 64 != 0);

    var fake = FakeSys.init(
        testing.allocator,
        v,
        testFix(line_length, line_length * 200),
    );
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, "/dev/fb0", fake.sys());
    defer dev.deinit();

    try testing.expect(!dev.doubleBuffered());
    try testing.expectEqual(@as(usize, 0), fake.callCount(.put_var));
    try testing.expectEqual(line_length, dev.buf_a.pitch);
    try testing.expectEqual(@as(usize, line_length * 100), fake.mmap_len);
    // yres_virtual was never touched because double buffering was rejected
    // before the PUT.
    try testing.expectEqual(@as(u32, 100), dev.var_info.yres_virtual);
}

test "pitch comes from line_length and row addressing honors it" {
    const line_length: u32 = 2624; // 41 * 64, 64-byte aligned
    var fake = FakeSys.init(
        testing.allocator,
        testVar(),
        testFix(line_length, line_length * 960),
    );
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, "/dev/fb0", fake.sys());
    defer dev.deinit();

    try testing.expect(dev.doubleBuffered());
    const frame = try dev.backend().beginFrame();
    try testing.expectEqual(line_length, frame.pitch);

    frame.set(639, 479, 0x00010203);
    const local = 479 * @as(usize, line_length) + 639 * 4;
    try testing.expectEqual(
        @as(u32, 0x00010203),
        std.mem.readInt(u32, frame.mem[local..][0..4], .little),
    );
    // beginFrame returned the high half, so its local offset is one frame in.
    const off = @as(usize, line_length) * 480 + local;
    try testing.expectEqual(
        @as(u32, 0x00010203),
        std.mem.readInt(u32, dev.mapping[off..][0..4], .little),
    );
    // Padding bytes between width*4 and pitch are untouched by set().
    const padding = @as(usize, line_length) * 480 + 479 * @as(usize, line_length) + 640 * 4;
    try testing.expectEqual(@as(u8, 0), dev.mapping[padding]);
}

test "setMode accepts only the current mode and re-applies it" {
    var fake = FakeSys.init(testing.allocator, testVar(), testFix(2560, 2560 * 960));
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, "/dev/fb0", fake.sys());
    defer dev.deinit();
    const be = dev.backend();

    try testing.expectError(error.Unsupported, be.setMode(1, 0));
    try testing.expectError(error.Unsupported, be.setMode(0, 1));
    try testing.expectError(error.Unsupported, be.setMode(5, 5));
    try testing.expectEqual(@as(usize, 1), fake.callCount(.put_var)); // only init's

    // Present one frame so the live yoffset is yres, then re-apply.
    _ = try be.beginFrame();
    try be.endFrame(&.{});
    try be.setMode(0, 0);
    try testing.expectEqual(@as(usize, 2), fake.callCount(.put_var));
    const put = fake.last(.put_var).?;
    try testing.expectEqual(@as(u32, 960), put.yres_virtual);
    try testing.expectEqual(@as(u32, 480), put.yoffset);
}

test "setDpms maps DPMS states to FB_BLANK levels" {
    var fake = FakeSys.init(testing.allocator, testVar(), testFix(2560, 2560 * 960));
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, "/dev/fb0", fake.sys());
    defer dev.deinit();
    const be = dev.backend();

    const cases = [_]struct { state: DpmsState, level: u32 }{
        .{ .state = .on, .level = FB_BLANK_UNBLANK },
        .{ .state = .standby, .level = FB_BLANK_NORMAL },
        .{ .state = .suspend_, .level = FB_BLANK_VSYNC_SUSPEND },
        .{ .state = .off, .level = FB_BLANK_POWERDOWN },
    };
    for (cases) |case| {
        try be.setDpms(case.state);
        const call = fake.last(.blank).?;
        try testing.expectEqual(case.level, @as(u32, @intCast(call.arg)));
        try testing.expectEqual(case.state, dev.dpms);
    }
    try testing.expectEqual(@as(usize, cases.len), fake.callCount(.blank));
}

test "setCursor is unsupported and no hardware cursor is advertised" {
    var fake = FakeSys.init(testing.allocator, testVar(), testFix(2560, 2560 * 960));
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, "/dev/fb0", fake.sys());
    defer dev.deinit();
    const be = dev.backend();

    try testing.expect(!be.supportsHwCursor());
    try testing.expectError(error.Unsupported, be.setCursor(null, 0, 0));
    var img = try Framebuffer.create(testing.allocator, 4, 4, .argb8888, null);
    defer img.destroy(testing.allocator);
    try testing.expectError(error.Unsupported, be.setCursor(&img, 10, 20));
}

test "16 bpp mode is rejected as UnsupportedDepth" {
    var v = testVar();
    v.bits_per_pixel = 16;
    v.red = .{ .offset = 11, .length = 5 };
    v.green = .{ .offset = 5, .length = 6 };
    v.blue = .{ .offset = 0, .length = 5 };
    v.transp = .{};

    var fake = FakeSys.init(testing.allocator, v, testFix(1280, 1280 * 480));
    defer fake.deinit();

    try testing.expectError(
        error.UnsupportedDepth,
        Fbdev.init(testing.allocator, "/dev/fb0", fake.sys()),
    );
    try testing.expect(fake.closed);
    try testing.expectEqual(@as(usize, 0), fake.callCount(.mmap));
}

test "pseudocolor visual is rejected as UnsupportedVisual" {
    var fix = testFix(2560, 2560 * 960);
    fix.visual = 3; // FB_VISUAL_PSEUDOCOLOR
    var fake = FakeSys.init(testing.allocator, testVar(), fix);
    defer fake.deinit();

    try testing.expectError(
        error.UnsupportedVisual,
        Fbdev.init(testing.allocator, "/dev/fb0", fake.sys()),
    );
    try testing.expect(fake.closed);
    try testing.expectEqual(@as(usize, 0), fake.callCount(.mmap));
}

test "non-XRGB8888 channel layout is rejected" {
    var v = testVar();
    v.red = .{ .offset = 0, .length = 8 }; // BGR order
    var fake = FakeSys.init(testing.allocator, v, testFix(2560, 2560 * 960));
    defer fake.deinit();

    try testing.expectError(
        error.UnsupportedPixelLayout,
        Fbdev.init(testing.allocator, "/dev/fb0", fake.sys()),
    );
    try testing.expect(fake.closed);
}

test "truncated framebuffer memory is rejected" {
    var fake = FakeSys.init(testing.allocator, testVar(), testFix(2560, 1000));
    defer fake.deinit();

    try testing.expectError(
        error.InvalidFramebuffer,
        Fbdev.init(testing.allocator, "/dev/fb0", fake.sys()),
    );
    try testing.expect(fake.closed);
    try testing.expectEqual(@as(usize, 0), fake.callCount(.mmap));
}

test "failed pan leaves the buffer swap undone" {
    var fake = FakeSys.init(testing.allocator, testVar(), testFix(2560, 2560 * 960));
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, "/dev/fb0", fake.sys());
    defer dev.deinit();
    const be = dev.backend();

    const first = try be.beginFrame();
    try testing.expectEqual(@intFromPtr(dev.buf_b.?.mem.ptr), @intFromPtr(first.mem.ptr));

    fake.fail_pan = true;
    try testing.expectError(error.IoctlFailed, be.endFrame(&.{}));
    try testing.expectEqual(@as(u32, 0), dev.var_info.yoffset);
    try testing.expect(!dev.scanout_high);

    // The next frame still targets the same (high) buffer.
    const retry = try be.beginFrame();
    try testing.expectEqual(@intFromPtr(first.mem.ptr), @intFromPtr(retry.mem.ptr));

    fake.fail_pan = false;
    try be.endFrame(&.{});
    try testing.expect(dev.scanout_high);
    const next = try be.beginFrame();
    try testing.expectEqual(@intFromPtr(dev.buf_a.mem.ptr), @intFromPtr(next.mem.ptr));
}

test "deinit unmaps, closes and frees metadata" {
    var fake = FakeSys.init(testing.allocator, testVar(), testFix(2560, 2560 * 960));
    defer fake.deinit();

    var dev = try Fbdev.init(testing.allocator, "/dev/fb0", fake.sys());
    dev.deinit();

    try testing.expect(fake.closed);
    try testing.expectEqual(@as(usize, 2560 * 960), fake.munmap_len);
    try testing.expect(fake.mapping == null);
}