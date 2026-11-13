//! src/video.zig -- video backend contract (ROADMAP §3, M1.3, M5).
//!
//! drm2d implements this first; drm3d and fbdev follow. The backend owns the
//! display hardware: modesetting, the back/front buffer pair, page flips,
//! DPMS and (optionally) a hardware cursor plane. Everything above it (the
//! session manager and renderer) talks only to `Backend`, never to libdrm.
//!
//! Threading (D2): one thread, one epoll loop. Frames are paced by DRM
//! page-flip events, so `endFrame` only *submits* a flip and returns; the
//! loop learns the flip completed through `flipPending`/`waitFlip` and the
//! backend's own event source. See `Backend.endFrame` for the exact contract.
//!
//! This file imports only std and framebuffer.zig (both contract-owned). The
//! layout glue (`LayoutConfig` below) is a placeholder seam; it does NOT
//! import src/video/layout.zig, which is being written concurrently and will
//! be unified in M1 integration.

const std = @import("std");
const fb = @import("framebuffer.zig");

pub const Framebuffer = fb.Framebuffer;
pub const PixelFormat = fb.PixelFormat;
pub const Damage = fb.Damage;

/// A display mode. Physical size in millimetres feeds the `font-size` auto
/// mode (ROADMAP M3.8): the renderer derives a pixel cell size from the
/// panel's physical dimensions so HiDPI panels get a readable font.
pub const Mode = struct {
    width_px: u32,
    height_px: u32,
    /// Refresh rate in millihertz (60000 = 60.000 Hz), matching DRM's
    /// DRM_MODE_PROP refresh granularity without floating point.
    refresh_mhz: u32,
    width_mm: u32,
    height_mm: u32,
};

/// One connector as reported by the backend. `name` and `card_name` are
/// borrowed from the backend and stay valid until the next `connectors()`
/// call or `deinit`. `modes` is the full probed list; `preferred_mode` and
/// `current_mode` index into it (null when absent / not yet modeset).
pub const ConnectorInfo = struct {
    /// Connector name, e.g. "HDMI-A-1".
    name: []const u8,
    /// Owning DRM card, e.g. "card0".
    card_name: []const u8,
    connected: bool,
    modes: []const Mode,
    preferred_mode: ?usize,
    current_mode: ?usize,
};

/// DPMS power states, mirroring the DRM connector DPMS property and the
/// values read back from /sys/class/drm/card*-*/dpms (ROADMAP M5.6, M8).
/// `suspend_` carries a trailing underscore because `suspend` is a Zig
/// keyword (same convention as loop.zig's `ev.in_`).
pub const DpmsState = enum {
    on,
    standby,
    suspend_,
    off,
};

/// The video backend interface, as a vtable + opaque pointer. Backends
/// (drm2d/drm3d/fbdev) fill a `VTable` whose first argument is their own
/// state pointer; callers hold a `Backend` and never see the concrete type.
///
/// All methods run on the single loop thread (D2). Errors are returned, not
/// panicked; a backend that cannot satisfy a request reports it so the
/// caller can degrade (e.g. software cursor on error.Unsupported).
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Release all backend resources (buffers, fds, DRM master).
        deinit: *const fn (ptr: *anyopaque) void,

        /// Enumerate connectors, refreshed for hotplug. The returned slice
        /// and its borrowed strings/modes are valid until the next call or
        /// deinit. Implementations re-probe so a plug/unplug is reflected.
        connectors: *const fn (ptr: *anyopaque) anyerror![]const ConnectorInfo,

        /// Modeset `connector_idx` to `mode_idx` (indices into the last
        /// `connectors()` result). Allocates/switches the scanout buffers.
        setMode: *const fn (ptr: *anyopaque, connector_idx: usize, mode_idx: usize) anyerror!void,

        /// Return the back buffer to draw the next frame into. The buffer
        /// is owned by the backend and stays valid until the next
        /// beginFrame; the caller must not free it. Drawing goes through
        /// framebuffer.zig accessors, which honor the buffer's pitch.
        beginFrame: *const fn (ptr: *anyopaque) anyerror!*Framebuffer,

        /// Submit a page flip presenting the back buffer, restricted to
        /// `damage` (empty slice = present everything). CONTRACT: this
        /// returns once the flip is SUBMITTED, not once it completes. The
        /// caller uses flipPending/waitFlip to pace the next frame (D2).
        /// `damage` is borrowed for the duration of the call only.
        endFrame: *const fn (ptr: *anyopaque, damage: []const Damage) anyerror!void,

        /// True while a submitted flip has not yet completed.
        flipPending: *const fn (ptr: *anyopaque) bool,

        /// Block until the pending flip completes (no-op when none is
        /// pending). Backends driven by the epoll loop may instead signal
        /// completion through their event source; waitFlip is the explicit
        /// pacing point for callers that want to stall.
        waitFlip: *const fn (ptr: *anyopaque) anyerror!void,

        /// Set the DPMS power state on the active connector(s).
        setDpms: *const fn (ptr: *anyopaque, state: DpmsState) anyerror!void,

        /// Position a hardware cursor image at (x, y), or hide it when
        /// `img` is null. Backends without a cursor plane return
        /// error.Unsupported so the renderer composites a software cursor.
        setCursor: *const fn (ptr: *anyopaque, img: ?*Framebuffer, x: i32, y: i32) anyerror!void,

        /// Whether setCursor can use a hardware cursor plane.
        supportsHwCursor: *const fn (ptr: *anyopaque) bool,
    };

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn connectors(self: Backend) anyerror![]const ConnectorInfo {
        return self.vtable.connectors(self.ptr);
    }

    pub fn setMode(self: Backend, connector_idx: usize, mode_idx: usize) anyerror!void {
        return self.vtable.setMode(self.ptr, connector_idx, mode_idx);
    }

    pub fn beginFrame(self: Backend) anyerror!*Framebuffer {
        return self.vtable.beginFrame(self.ptr);
    }

    pub fn endFrame(self: Backend, damage: []const Damage) anyerror!void {
        return self.vtable.endFrame(self.ptr, damage);
    }

    pub fn flipPending(self: Backend) bool {
        return self.vtable.flipPending(self.ptr);
    }

    pub fn waitFlip(self: Backend) anyerror!void {
        return self.vtable.waitFlip(self.ptr);
    }

    pub fn setDpms(self: Backend, state: DpmsState) anyerror!void {
        return self.vtable.setDpms(self.ptr, state);
    }

    pub fn setCursor(self: Backend, img: ?*Framebuffer, x: i32, y: i32) anyerror!void {
        return self.vtable.setCursor(self.ptr, img, x, y);
    }

    pub fn supportsHwCursor(self: Backend) bool {
        return self.vtable.supportsHwCursor(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// Layout glue seam.
//
// These are minimal placeholder types so video.zig compiles standalone. They
// are TO BE UNIFIED with src/video/layout.zig in M1 integration: that module
// (being written concurrently) owns the real multi-monitor layout algorithm
// (clone/largest/scaled, per-connector rotation and disable, cell grid math).
// Do not import src/video/layout.zig here; when it lands, replace these
// declarations with re-exports of its types.
// ---------------------------------------------------------------------------

/// Multi-monitor policy, matching the `multi-monitor=` option values
/// (kmscon-options.md §5.8). `scaled` is the kmscon default.
pub const MultiMonitorMode = enum {
    clone,
    largest,
    scaled,
};

/// Per-connector layout input: which connector, whether it is enabled, and
/// its rotation. Placeholder for the richer per-connector config that
/// src/video/layout.zig will define (screen= orientation/disable).
pub const ConnectorLayoutInput = struct {
    connector_idx: usize,
    enabled: bool = true,
    /// Rotation in degrees clockwise: 0, 90, 180, 270.
    rotation_deg: u16 = 0,
};

/// Minimal layout configuration handed to the layout glue. Placeholder; to
/// be unified with src/video/layout.zig in M1 integration.
pub const LayoutConfig = struct {
    multi_monitor: MultiMonitorMode,
    connectors: []const ConnectorLayoutInput,
    cell_w: u16,
    cell_h: u16,
};

// ---------------------------------------------------------------------------
// Tests: prove the vtable interface is implementable and that Damage slices
// pass through endFrame unchanged.
// ---------------------------------------------------------------------------

/// In-file mock backend recording every call. It owns a real Framebuffer so
/// beginFrame returns something drawable, and it captures the damage slice
/// contents passed to endFrame.
const MockBackend = struct {
    buffer: Framebuffer,
    allocator: std.mem.Allocator,

    calls: std.ArrayList(Call) = .empty,
    /// Copy of the damage rects from the most recent endFrame.
    last_damage: std.ArrayList(Damage) = .empty,
    pending: bool = false,
    hw_cursor: bool = true,
    dpms: DpmsState = .on,
    mode_set: ?struct { connector: usize, mode: usize } = null,
    cursor: ?struct { x: i32, y: i32 } = null,
    cursor_hidden: bool = false,

    const Call = enum {
        deinit,
        connectors,
        set_mode,
        begin_frame,
        end_frame,
        flip_pending,
        wait_flip,
        set_dpms,
        set_cursor,
        supports_hw_cursor,
    };

    const mode_list = [_]Mode{
        .{ .width_px = 1920, .height_px = 1080, .refresh_mhz = 60000, .width_mm = 530, .height_mm = 300 },
        .{ .width_px = 1280, .height_px = 720, .refresh_mhz = 60000, .width_mm = 530, .height_mm = 300 },
    };
    const connector_list = [_]ConnectorInfo{
        .{
            .name = "HDMI-A-1",
            .card_name = "card0",
            .connected = true,
            .modes = &mode_list,
            .preferred_mode = 0,
            .current_mode = null,
        },
    };

    fn init(allocator: std.mem.Allocator) !MockBackend {
        return .{
            .buffer = try Framebuffer.create(allocator, 64, 48, .xrgb8888, null),
            .allocator = allocator,
        };
    }

    fn deinit(self: *MockBackend) void {
        self.calls.deinit(self.allocator);
        self.last_damage.deinit(self.allocator);
        self.buffer.destroy(self.allocator);
    }

    fn backend(self: *MockBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn record(self: *MockBackend, call: Call) void {
        self.calls.append(self.allocator, call) catch @panic("mock: oom recording call");
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

    fn cast(ptr: *anyopaque) *MockBackend {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).record(.deinit);
    }

    fn vtConnectors(ptr: *anyopaque) anyerror![]const ConnectorInfo {
        const m = cast(ptr);
        m.record(.connectors);
        return &connector_list;
    }

    fn vtSetMode(ptr: *anyopaque, connector_idx: usize, mode_idx: usize) anyerror!void {
        const m = cast(ptr);
        m.record(.set_mode);
        if (connector_idx >= connector_list.len) return error.InvalidConnector;
        if (mode_idx >= mode_list.len) return error.InvalidMode;
        m.mode_set = .{ .connector = connector_idx, .mode = mode_idx };
    }

    fn vtBeginFrame(ptr: *anyopaque) anyerror!*Framebuffer {
        const m = cast(ptr);
        m.record(.begin_frame);
        return &m.buffer;
    }

    fn vtEndFrame(ptr: *anyopaque, damage: []const Damage) anyerror!void {
        const m = cast(ptr);
        m.record(.end_frame);
        m.last_damage.clearRetainingCapacity();
        for (damage) |d| {
            try m.last_damage.append(m.allocator, d);
        }
        m.pending = true;
    }

    fn vtFlipPending(ptr: *anyopaque) bool {
        const m = cast(ptr);
        m.record(.flip_pending);
        return m.pending;
    }

    fn vtWaitFlip(ptr: *anyopaque) anyerror!void {
        const m = cast(ptr);
        m.record(.wait_flip);
        m.pending = false;
    }

    fn vtSetDpms(ptr: *anyopaque, state: DpmsState) anyerror!void {
        const m = cast(ptr);
        m.record(.set_dpms);
        m.dpms = state;
    }

    fn vtSetCursor(ptr: *anyopaque, img: ?*Framebuffer, x: i32, y: i32) anyerror!void {
        const m = cast(ptr);
        m.record(.set_cursor);
        if (!m.hw_cursor) return error.Unsupported;
        if (img == null) {
            m.cursor_hidden = true;
            m.cursor = null;
        } else {
            m.cursor_hidden = false;
            m.cursor = .{ .x = x, .y = y };
        }
    }

    fn vtSupportsHwCursor(ptr: *anyopaque) bool {
        const m = cast(ptr);
        m.record(.supports_hw_cursor);
        return m.hw_cursor;
    }
};

test "video: vtable dispatch through a mock backend" {
    const a = std.testing.allocator;
    var mock = try MockBackend.init(a);
    defer mock.deinit();
    const b = mock.backend();

    // connectors() returns the probed list with borrowed metadata.
    const conns = try b.connectors();
    try std.testing.expectEqual(@as(usize, 1), conns.len);
    try std.testing.expectEqualStrings("HDMI-A-1", conns[0].name);
    try std.testing.expectEqualStrings("card0", conns[0].card_name);
    try std.testing.expect(conns[0].connected);
    try std.testing.expectEqual(@as(usize, 2), conns[0].modes.len);
    try std.testing.expectEqual(@as(?usize, 0), conns[0].preferred_mode);
    try std.testing.expectEqual(@as(u32, 530), conns[0].modes[0].width_mm);

    // setMode records indices and validates bounds.
    try b.setMode(0, 1);
    try std.testing.expectEqual(@as(usize, 1), mock.mode_set.?.mode);
    try std.testing.expectError(error.InvalidMode, b.setMode(0, 99));
    try std.testing.expectError(error.InvalidConnector, b.setMode(5, 0));

    // beginFrame hands back a drawable backend-owned buffer.
    const buf = try b.beginFrame();
    try std.testing.expectEqual(@as(u32, 64), buf.width);
    buf.set(3, 4, 0xAABBCCDD);
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), buf.get(3, 4));

    // DPMS and cursor queries dispatch.
    try std.testing.expect(b.supportsHwCursor());
    try b.setDpms(.off);
    try std.testing.expectEqual(DpmsState.off, mock.dpms);
    try b.setCursor(buf, 10, 20);
    try std.testing.expectEqual(@as(i32, 10), mock.cursor.?.x);
    try b.setCursor(null, 0, 0);
    try std.testing.expect(mock.cursor_hidden);

    // A backend without a cursor plane reports Unsupported.
    mock.hw_cursor = false;
    try std.testing.expect(!b.supportsHwCursor());
    try std.testing.expectError(error.Unsupported, b.setCursor(buf, 0, 0));
}

test "video: endFrame passes Damage slices through and paces flips" {
    const a = std.testing.allocator;
    var mock = try MockBackend.init(a);
    defer mock.deinit();
    const b = mock.backend();

    _ = try b.beginFrame();
    try std.testing.expect(!b.flipPending());

    const damage = [_]Damage{
        Damage.fromRows(2, 5, 64),
        .{ .x = 10, .y = 10, .w = 8, .h = 8 },
    };
    try b.endFrame(&damage);

    // Damage rects arrive unchanged, in order.
    try std.testing.expectEqual(@as(usize, 2), mock.last_damage.items.len);
    try std.testing.expectEqual(damage[0], mock.last_damage.items[0]);
    try std.testing.expectEqual(damage[1], mock.last_damage.items[1]);

    // endFrame submitted the flip: pending until waitFlip completes it.
    try std.testing.expect(b.flipPending());
    try b.waitFlip();
    try std.testing.expect(!b.flipPending());
    // waitFlip with nothing pending is a no-op.
    try b.waitFlip();
    try std.testing.expect(!b.flipPending());

    // Empty damage slice is accepted (present everything).
    try b.endFrame(&.{});
    try std.testing.expectEqual(@as(usize, 0), mock.last_damage.items.len);
    try b.waitFlip();

    // Call order was recorded through the vtable.
    const expected = [_]MockBackend.Call{
        .begin_frame,
        .flip_pending,
        .end_frame,
        .flip_pending,
        .wait_flip,
        .flip_pending,
        .wait_flip,
        .flip_pending,
        .end_frame,
        .wait_flip,
    };
    try std.testing.expectEqualSlices(MockBackend.Call, &expected, mock.calls.items);
}

test "video: LayoutConfig seam constructs with placeholder types" {
    const inputs = [_]ConnectorLayoutInput{
        .{ .connector_idx = 0, .enabled = true, .rotation_deg = 0 },
        .{ .connector_idx = 1, .enabled = false, .rotation_deg = 90 },
    };
    const cfg = LayoutConfig{
        .multi_monitor = .scaled,
        .connectors = &inputs,
        .cell_w = 8,
        .cell_h = 16,
    };
    try std.testing.expectEqual(MultiMonitorMode.scaled, cfg.multi_monitor);
    try std.testing.expectEqual(@as(usize, 2), cfg.connectors.len);
    try std.testing.expect(!cfg.connectors[1].enabled);
    try std.testing.expectEqual(@as(u16, 90), cfg.connectors[1].rotation_deg);
}
