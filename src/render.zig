//! src/render.zig -- renderer contract (ROADMAP §3, M1.5 CPU renderer, M5
//! GL renderer).
//!
//! The renderer turns a terminal render state into pixels in a Framebuffer.
//! The CPU renderer lands in M1; the GL renderer in M5. Both implement the
//! `Renderer` vtable below so the session manager can swap them without
//! knowing which is active.
//!
//! The render state is passed as `*const anyopaque` on purpose: the concrete
//! type is the vt.zig render-state wrapper (the only file that touches the
//! libghostty-vt C API, decision D1). That wrapper lands in M1 phase A
//! integration; keeping the pointer opaque means render.zig has NO ghostty
//! dependency and compiles/tests standalone today. The concrete type will be
//! documented and cast at the call site once it exists.
//!
//! Imports: std + framebuffer.zig + video/layout.zig (all contract-owned;
//! layout.zig itself imports only std). session.zig declares the identical
//! `DamageList` alias (the same type) without importing this file.

const std = @import("std");
const fb = @import("framebuffer.zig");
const layout = @import("video/layout.zig");

pub const Framebuffer = fb.Framebuffer;
pub const PixelFormat = fb.PixelFormat;
pub const Damage = fb.Damage;

/// Accumulated damage rectangles for one frame. Unmanaged: the caller owns
/// the allocator and passes it to every mutating call (`append`, `deinit`).
/// The session/render owner clears it between frames with
/// `clearRetainingCapacity` to reuse the allocation.
pub const DamageList = std.ArrayListUnmanaged(Damage);

/// Cursor presentation style (ROADMAP M3.7 cursor styles).
pub const CursorStyle = enum {
    block,
    bar,
    underline,
};

/// Per-frame rendering options. Colors are packed 0xRRGGBB words (alpha is
/// handled separately via bg_opacity). `palette` is the 18-entry table:
/// 16 ANSI colors followed by default foreground and default background
/// (kmscon-options.md §5.10, TSM_COLOR_* slots).
pub const RenderOpts = struct {
    cursor_visible: bool,
    cursor_style: CursorStyle,
    /// Blink phase: null = not blinking (steady), true = on-phase,
    /// false = off-phase. The session drives this from its blink timer.
    cursor_blink_on: ?bool,
    /// 16 ANSI colors + foreground + background.
    palette: *const [18]u32,
    default_fg: u32,
    default_bg: u32,
    /// Background opacity 0 (transparent) .. 255 (opaque).
    bg_opacity: u8,
};

/// Cell grid geometry derived from a framebuffer and a font cell size.
/// `baseline` is the glyph baseline offset in pixels from the top of a cell
/// (positive down). `cols`/`rows` are the whole cells that fit; any leftover
/// pixels are split evenly as padding so the grid is centered.
pub const CellMetrics = struct {
    cell_w: u16,
    cell_h: u16,
    baseline: i16,
    cols: u16,
    rows: u16,
    /// Left padding in pixels (centering remainder).
    pad_x: u16,
    /// Top padding in pixels (centering remainder).
    pad_y: u16,
};

/// Compute the cell grid for a framebuffer of `fb_width` x `fb_height`
/// pixels using a font cell of `font_cell_w` x `font_cell_h` pixels. Whole
/// cells are floored; the leftover pixels are centered (half on each side,
/// the odd pixel going to the far side). A zero cell dimension yields zero
/// cols/rows rather than dividing by zero.
///
/// The baseline is placed at 4/5 of the cell height (a common monospace
/// ascent), clamped to at least 1px for non-empty cells. Concrete font
/// metrics will refine this in M3 when real faces are loaded.
pub fn computeMetrics(fb_width: u32, fb_height: u32, font_cell_w: u16, font_cell_h: u16) CellMetrics {
    if (font_cell_w == 0 or font_cell_h == 0) {
        return .{
            .cell_w = font_cell_w,
            .cell_h = font_cell_h,
            .baseline = 0,
            .cols = 0,
            .rows = 0,
            .pad_x = @intCast(@min(fb_width, std.math.maxInt(u16))),
            .pad_y = @intCast(@min(fb_height, std.math.maxInt(u16))),
        };
    }
    const cols: u32 = fb_width / font_cell_w;
    const rows: u32 = fb_height / font_cell_h;
    const used_w = cols * font_cell_w;
    const used_h = rows * font_cell_h;
    const rem_x = fb_width - used_w;
    const rem_y = fb_height - used_h;
    const baseline: i16 = @intCast(@max(1, (@as(u32, font_cell_h) * 4) / 5));
    return .{
        .cell_w = font_cell_w,
        .cell_h = font_cell_h,
        .baseline = baseline,
        .cols = @intCast(@min(cols, std.math.maxInt(u16))),
        .rows = @intCast(@min(rows, std.math.maxInt(u16))),
        .pad_x = @intCast(@min(rem_x / 2, std.math.maxInt(u16))),
        .pad_y = @intCast(@min(rem_y / 2, std.math.maxInt(u16))),
    };
}

/// The renderer interface, as a vtable + opaque pointer. Implementations
/// (cpu now, gl in M5) hold their own state (glyph atlas, scratch buffers)
/// behind `ptr`; callers hold a `Renderer`.
///
/// All methods run on the single loop thread (D2). `renderFrame` draws into
/// the caller-provided framebuffer and appends the rectangles it touched to
/// `damage`; it does not present or flip (that is video.Backend's job).
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Release renderer resources (atlas, scratch buffers).
        deinit: *const fn (ptr: *anyopaque) void,

        /// Reconfigure for a new grid. Called on mode change / resize with
        /// reflow (ROADMAP M2.5). The renderer reallocates any size-dependent
        /// scratch space here, not per frame.
        resize: *const fn (ptr: *anyopaque, new_cols: u16, new_rows: u16, cell_w: u16, cell_h: u16) anyerror!void,

        /// Draw the current terminal state into `fb`, appending touched
        /// rectangles to `damage`. `state` is an opaque pointer to the vt.zig
        /// render-state wrapper (concrete type lands in M1 phase A
        /// integration); the renderer casts it to the agreed type. `opts`
        /// carries cursor/palette/opacity for this frame.
        renderFrame: *const fn (
            ptr: *anyopaque,
            state: *const anyopaque,
            fb: *Framebuffer,
            damage: *DamageList,
            opts: RenderOpts,
        ) anyerror!void,
    };

    pub fn deinit(self: Renderer) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn resize(self: Renderer, new_cols: u16, new_rows: u16, cell_w: u16, cell_h: u16) anyerror!void {
        return self.vtable.resize(self.ptr, new_cols, new_rows, cell_w, cell_h);
    }

    pub fn renderFrame(
        self: Renderer,
        state: *const anyopaque,
        fb_buf: *Framebuffer,
        damage: *DamageList,
        opts: RenderOpts,
    ) anyerror!void {
        return self.vtable.renderFrame(self.ptr, state, fb_buf, damage, opts);
    }
};

/// Present the shared terminal canvas (`src`, in canvas/logical pixel space)
/// into one connector's physical back buffer (`dst`) through a layout.Plan
/// viewport (ROADMAP M5.4): crop `plan.src`, scale uniformly by `plan.scale`
/// into `plan.dst` (content space, centered), then rotate onto the native
/// framebuffer with `plan.conn.rotation`. Nearest-neighbour sampling keeps
/// glyph edges crisp at integer scales. Formats must match; words are copied
/// verbatim. Pixels outside the viewport are left untouched (the caller
/// clears the letterbox). The 1:1 unrotated full-canvas case is faster via
/// Framebuffer.blitFrom and is handled at the call site.
pub fn blitViewport(dst: Framebuffer, src: Framebuffer, plan: layout.Plan) void {
    if (!plan.active or plan.scale <= 0) return;
    const dh: u32 = @intFromFloat(@round(plan.dst.h));
    blitViewportRows(dst, src, plan, 0, dh);
}

/// Band-limited blitViewport: repaint only the destination content rows that
/// canvas rows [y0, y1) map to, leaving every other pixel untouched. Sampling
/// is the shared row loop below, so a band blit is pixel-identical to the full
/// blit restricted to those rows. The band-limited present path uses this so
/// pointer/small-damage frames do not repaint the whole canvas (a fractional
/// letterbox or a scaled/rotated viewport otherwise forces a full-canvas blit
/// every frame). The content-row band is over-covered by <1 row at each edge
/// (floor/ceil), never under-covered; over-cover only repaints correct shadow
/// pixels, so it cannot leave a ghost.
pub fn blitViewportBand(dst: Framebuffer, src: Framebuffer, plan: layout.Plan, y0: u32, y1: u32) void {
    if (!plan.active or plan.scale <= 0) return;
    const dh: u32 = @intFromFloat(@round(plan.dst.h));
    if (dh == 0 or plan.src.w == 0 or plan.src.h == 0) return;
    // Clip the canvas band to the viewport's source rows.
    const sy0: i64 = @max(@as(i64, y0), @as(i64, plan.src.y));
    const sy1: i64 = @min(@as(i64, y1), plan.src.endY());
    if (sy1 <= sy0) return;
    // Map the canvas band to destination content-row indices (the same
    // floor(dst) origin and scale the row loop samples with).
    const fsy: f64 = @floatFromInt(plan.src.y);
    const c0 = (@as(f64, @floatFromInt(sy0)) - fsy) * plan.scale;
    const c1 = (@as(f64, @floatFromInt(sy1)) - fsy) * plan.scale;
    const fdh: f64 = @floatFromInt(dh);
    const cy0: u32 = @intFromFloat(std.math.clamp(@floor(c0), 0.0, fdh));
    const cy1: u32 = @intFromFloat(std.math.clamp(@ceil(c1), 0.0, fdh));
    if (cy1 <= cy0) return;
    blitViewportRows(dst, src, plan, cy0, cy1);
}

/// Shared blitViewport row loop. Iterates every destination content row so the
/// accumulated 1/scale sampling stays identical to a full blit, but paints only
/// rows in [cy0, cy1); the skipped rows cost a compare and an fp add, not the
/// per-pixel sample/rotate/write.
fn blitViewportRows(dst: Framebuffer, src: Framebuffer, plan: layout.Plan, cy0: u32, cy1: u32) void {
    std.debug.assert(dst.format == src.format);
    const inv = 1.0 / plan.scale;
    const rot = plan.conn.rotation;
    const pw = plan.conn.width_px;
    const ph = plan.conn.height_px;
    const dx0: i32 = @intFromFloat(@floor(plan.dst.x));
    const dy0: i32 = @intFromFloat(@floor(plan.dst.y));
    const dw: u32 = @intFromFloat(@round(plan.dst.w));
    const dh: u32 = @intFromFloat(@round(plan.dst.h));
    if (dw == 0 or dh == 0 or plan.src.w == 0 or plan.src.h == 0) return;

    var cy: u32 = 0;
    var fy: f64 = @floatFromInt(plan.src.y);
    while (cy < dh) : (cy += 1) {
        if (cy >= cy0 and cy < cy1) {
            const sy: u32 = @intFromFloat(@floor(fy));
            const content_y = dy0 + @as(i32, @intCast(cy));
            var cx: u32 = 0;
            var fx: f64 = @floatFromInt(plan.src.x);
            while (cx < dw) : (cx += 1) {
                const sx: u32 = @intFromFloat(@floor(fx));
                if (sx < src.width and sy < src.height) {
                    const word = src.get(sx, sy);
                    const content_x = dx0 + @as(i32, @intCast(cx));
                    const p = rot.logicalToPhysical(content_x, content_y, pw, ph);
                    if (p.x >= 0 and p.y >= 0 and p.x < dst.width and p.y < dst.height) {
                        dst.set(@intCast(p.x), @intCast(p.y), word);
                    }
                }
                fx += inv;
            }
        }
        fy += inv;
    }
}

// ---------------------------------------------------------------------------
// Tests: computeMetrics centering math and a mock renderer through the
// vtable.
// ---------------------------------------------------------------------------

test "render: computeMetrics exact division has no padding" {
    const m = computeMetrics(640, 480, 8, 16);
    try std.testing.expectEqual(@as(u16, 80), m.cols);
    try std.testing.expectEqual(@as(u16, 30), m.rows);
    try std.testing.expectEqual(@as(u16, 0), m.pad_x);
    try std.testing.expectEqual(@as(u16, 0), m.pad_y);
    try std.testing.expectEqual(@as(u16, 8), m.cell_w);
    try std.testing.expectEqual(@as(u16, 16), m.cell_h);
    // Baseline 4/5 of 16 = 12 (integer).
    try std.testing.expectEqual(@as(i16, 12), m.baseline);
}

test "render: computeMetrics non-exact division centers the remainder" {
    // 643 = 80*8 + 3 -> pad_x = 1 (3/2). 481 = 30*16 + 1 -> pad_y = 0.
    const m = computeMetrics(643, 481, 8, 16);
    try std.testing.expectEqual(@as(u16, 80), m.cols);
    try std.testing.expectEqual(@as(u16, 30), m.rows);
    try std.testing.expectEqual(@as(u16, 1), m.pad_x);
    try std.testing.expectEqual(@as(u16, 0), m.pad_y);

    // Larger remainder: 650 = 81*8 + 2 -> pad_x = 1; 490 = 30*16 + 10 -> pad_y = 5.
    const m2 = computeMetrics(650, 490, 8, 16);
    try std.testing.expectEqual(@as(u16, 81), m2.cols);
    try std.testing.expectEqual(@as(u16, 30), m2.rows);
    try std.testing.expectEqual(@as(u16, 1), m2.pad_x);
    try std.testing.expectEqual(@as(u16, 5), m2.pad_y);

    // Remainder smaller than a cell never adds a column/row.
    const m3 = computeMetrics(7, 15, 8, 16);
    try std.testing.expectEqual(@as(u16, 0), m3.cols);
    try std.testing.expectEqual(@as(u16, 0), m3.rows);
    try std.testing.expectEqual(@as(u16, 3), m3.pad_x);
    try std.testing.expectEqual(@as(u16, 7), m3.pad_y);
}

test "render: computeMetrics zero cell size is safe" {
    const m = computeMetrics(640, 480, 0, 16);
    try std.testing.expectEqual(@as(u16, 0), m.cols);
    try std.testing.expectEqual(@as(u16, 0), m.rows);
    const m2 = computeMetrics(640, 480, 8, 0);
    try std.testing.expectEqual(@as(u16, 0), m2.rows);
}

/// In-file mock renderer recording calls and writing a recognizable pattern
/// so renderFrame's framebuffer + damage plumbing is observable.
const MockRenderer = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList(Call) = .empty,
    grid: ?struct { cols: u16, rows: u16, cell_w: u16, cell_h: u16 } = null,
    rendered: usize = 0,

    const Call = enum { resize, render_frame, deinit };

    fn init(allocator: std.mem.Allocator) MockRenderer {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MockRenderer) void {
        self.calls.deinit(self.allocator);
    }

    fn renderer(self: *MockRenderer) Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn record(self: *MockRenderer, call: Call) void {
        self.calls.append(self.allocator, call) catch @panic("mock: oom recording call");
    }

    const vtable = Renderer.VTable{
        .deinit = vtDeinit,
        .resize = vtResize,
        .renderFrame = vtRenderFrame,
    };

    fn cast(ptr: *anyopaque) *MockRenderer {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtDeinit(ptr: *anyopaque) void {
        cast(ptr).record(.deinit);
    }

    fn vtResize(ptr: *anyopaque, new_cols: u16, new_rows: u16, cell_w: u16, cell_h: u16) anyerror!void {
        const m = cast(ptr);
        m.record(.resize);
        m.grid = .{ .cols = new_cols, .rows = new_rows, .cell_w = cell_w, .cell_h = cell_h };
    }

    fn vtRenderFrame(
        ptr: *anyopaque,
        state: *const anyopaque,
        fb_buf: *Framebuffer,
        damage: *DamageList,
        opts: RenderOpts,
    ) anyerror!void {
        const m = cast(ptr);
        m.record(.render_frame);
        m.rendered += 1;
        // The opaque state pointer must arrive unchanged.
        const tag: *const u32 = @ptrCast(@alignCast(state));
        // Paint the top-left cell with the default foreground and record it.
        fb_buf.set(0, 0, opts.default_fg);
        try damage.append(m.allocator, .{ .x = 0, .y = 0, .w = opts.palette[0], .h = 1 });
        _ = tag;
    }
};

test "render: mock renderer dispatches through the vtable" {
    const a = std.testing.allocator;
    var mock = MockRenderer.init(a);
    defer mock.deinit();
    const r = mock.renderer();

    try r.resize(80, 24, 8, 16);
    try std.testing.expectEqual(@as(u16, 80), mock.grid.?.cols);
    try std.testing.expectEqual(@as(u16, 24), mock.grid.?.rows);

    var fb_buf = try Framebuffer.create(a, 64, 48, .xrgb8888, null);
    defer fb_buf.destroy(a);
    var damage: DamageList = .empty;
    defer damage.deinit(a);

    const palette: [18]u32 = @splat(0);
    const opts = RenderOpts{
        .cursor_visible = true,
        .cursor_style = .block,
        .cursor_blink_on = null,
        .palette = &palette,
        .default_fg = 0x00FF00,
        .default_bg = 0x000000,
        .bg_opacity = 255,
    };
    // Opaque state: a stand-in value the mock receives untouched.
    var state_value: u32 = 0xC0FFEE;
    try r.renderFrame(&state_value, &fb_buf, &damage, opts);

    try std.testing.expectEqual(@as(u32, 0x00FF00), fb_buf.get(0, 0));
    try std.testing.expectEqual(@as(usize, 1), damage.items.len);
    try std.testing.expectEqual(@as(usize, 1), mock.rendered);

    // Second frame appends more damage (accumulation, not replacement).
    try r.renderFrame(&state_value, &fb_buf, &damage, opts);
    try std.testing.expectEqual(@as(usize, 2), damage.items.len);

    const expected = [_]MockRenderer.Call{ .resize, .render_frame, .render_frame };
    try std.testing.expectEqualSlices(MockRenderer.Call, &expected, mock.calls.items);
}

test "render: RenderOpts carries all cursor styles and blink phases" {
    const palette: [18]u32 = @splat(0x111111);
    inline for (.{ CursorStyle.block, CursorStyle.bar, CursorStyle.underline }) |style| {
        const opts = RenderOpts{
            .cursor_visible = true,
            .cursor_style = style,
            .cursor_blink_on = true,
            .palette = &palette,
            .default_fg = 0xFFFFFF,
            .default_bg = 0x000000,
            .bg_opacity = 128,
        };
        try std.testing.expectEqual(style, opts.cursor_style);
        try std.testing.expectEqual(@as(?bool, true), opts.cursor_blink_on);
        try std.testing.expectEqual(@as(u8, 128), opts.bg_opacity);
        try std.testing.expectEqual(@as(usize, 18), opts.palette.len);
    }
}

// ---------------------------------------------------------------------------
// blitViewport: multi-monitor present (crop / scale / rotate / center).
// ---------------------------------------------------------------------------

fn fillPattern(f: Framebuffer) void {
    var y: u32 = 0;
    while (y < f.height) : (y += 1) {
        var x: u32 = 0;
        while (x < f.width) : (x += 1) {
            f.set(x, y, 0x10000 * (x + 1) + 0x100 * (y + 1));
        }
    }
}

test "blitViewport: 1:1 normal full canvas is an exact copy" {
    const a = std.testing.allocator;
    var src = try Framebuffer.create(a, 4, 2, .xrgb8888, null);
    defer src.destroy(a);
    var dst = try Framebuffer.create(a, 4, 2, .xrgb8888, null);
    defer dst.destroy(a);
    fillPattern(src);
    const plan = layout.Plan{
        .active = true,
        .conn = .{ .width_px = 4, .height_px = 2, .rotation = .normal },
        .src = .{ .x = 0, .y = 0, .w = 4, .h = 2 },
        .scale = 1,
        .dst = .{ .x = 0, .y = 0, .w = 4, .h = 2 },
    };
    blitViewport(dst, src, plan);
    var y: u32 = 0;
    while (y < 2) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) try std.testing.expectEqual(src.get(x, y), dst.get(x, y));
    }
}

test "blitViewport: 1:1 normal centered leaves the letterbox untouched" {
    const a = std.testing.allocator;
    var src = try Framebuffer.create(a, 2, 2, .xrgb8888, null);
    defer src.destroy(a);
    var dst = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer dst.destroy(a);
    fillPattern(src);
    dst.fill(0xABABAB);
    const plan = layout.Plan{
        .active = true,
        .conn = .{ .width_px = 4, .height_px = 4, .rotation = .normal },
        .src = .{ .x = 0, .y = 0, .w = 2, .h = 2 },
        .scale = 1,
        .dst = .{ .x = 1, .y = 1, .w = 2, .h = 2 },
    };
    blitViewport(dst, src, plan);
    try std.testing.expectEqual(src.get(0, 0), dst.get(1, 1));
    try std.testing.expectEqual(src.get(1, 1), dst.get(2, 2));
    // Border keeps the sentinel.
    try std.testing.expectEqual(@as(u32, 0xABABAB), dst.get(0, 0));
    try std.testing.expectEqual(@as(u32, 0xABABAB), dst.get(3, 3));
}

test "blitViewport: nearest-neighbour 2x upscale blocks" {
    const a = std.testing.allocator;
    var src = try Framebuffer.create(a, 2, 2, .xrgb8888, null);
    defer src.destroy(a);
    var dst = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer dst.destroy(a);
    fillPattern(src);
    const plan = layout.Plan{
        .active = true,
        .conn = .{ .width_px = 4, .height_px = 4, .rotation = .normal },
        .src = .{ .x = 0, .y = 0, .w = 2, .h = 2 },
        .scale = 2,
        .dst = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
    };
    blitViewport(dst, src, plan);
    try std.testing.expectEqual(src.get(0, 0), dst.get(0, 0));
    try std.testing.expectEqual(src.get(0, 0), dst.get(1, 1));
    try std.testing.expectEqual(src.get(1, 0), dst.get(2, 0));
    try std.testing.expectEqual(src.get(1, 0), dst.get(3, 1));
    try std.testing.expectEqual(src.get(0, 1), dst.get(0, 2));
    try std.testing.expectEqual(src.get(1, 1), dst.get(3, 3));
}

test "blitViewport: right rotation maps content corners to the native frame" {
    const a = std.testing.allocator;
    var src = try Framebuffer.create(a, 4, 2, .xrgb8888, null);
    defer src.destroy(a);
    var dst = try Framebuffer.create(a, 2, 4, .xrgb8888, null);
    defer dst.destroy(a);
    fillPattern(src);
    const plan = layout.Plan{
        .active = true,
        .conn = .{ .width_px = 2, .height_px = 4, .rotation = .right },
        .src = .{ .x = 0, .y = 0, .w = 4, .h = 2 },
        .scale = 1,
        .dst = .{ .x = 0, .y = 0, .w = 4, .h = 2 },
    };
    blitViewport(dst, src, plan);
    // .right: physical = (pw-1-y, x) with pw=2.
    try std.testing.expectEqual(src.get(0, 0), dst.get(1, 0));
    try std.testing.expectEqual(src.get(3, 0), dst.get(1, 3));
    try std.testing.expectEqual(src.get(0, 1), dst.get(0, 0));
    try std.testing.expectEqual(src.get(3, 1), dst.get(0, 3));
}

test "blitViewport: inactive plan is a no-op" {
    const a = std.testing.allocator;
    var src = try Framebuffer.create(a, 2, 2, .xrgb8888, null);
    defer src.destroy(a);
    var dst = try Framebuffer.create(a, 2, 2, .xrgb8888, null);
    defer dst.destroy(a);
    fillPattern(src);
    dst.fill(0);
    blitViewport(dst, src, .{ .active = false });
    try std.testing.expectEqual(@as(u32, 0), dst.get(0, 0));
}

test "blitViewportBand: repaints only the band, pixel-identical to a full blit" {
    const a = std.testing.allocator;
    var src = try Framebuffer.create(a, 8, 8, .xrgb8888, null);
    defer src.destroy(a);
    fillPattern(src);
    // Fractional letterbox (dst.y = 1.5): the real-hardware case that defeats
    // the aligned fast path and forces the viewport path.
    const plan = layout.Plan{
        .active = true,
        .conn = .{ .width_px = 8, .height_px = 11, .rotation = .normal },
        .src = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .scale = 1,
        .dst = .{ .x = 0, .y = 1.5, .w = 8, .h = 8 },
    };
    var full = try Framebuffer.create(a, 8, 11, .xrgb8888, null);
    defer full.destroy(a);
    full.fill(0);
    blitViewport(full, src, plan);

    var band = try Framebuffer.create(a, 8, 11, .xrgb8888, null);
    defer band.destroy(a);
    band.fill(0xABABAB);
    blitViewportBand(band, src, plan, 2, 5);
    // Canvas rows [2,5) at scale 1 with floor(dst.y)=1 land on content rows
    // [3,6); those must equal the full blit, every other row keeps the sentinel.
    var y: u32 = 0;
    while (y < 11) : (y += 1) {
        var x: u32 = 0;
        while (x < 8) : (x += 1) {
            if (y >= 3 and y < 6) {
                try std.testing.expectEqual(full.get(x, y), band.get(x, y));
            } else {
                try std.testing.expectEqual(@as(u32, 0xABABAB), band.get(x, y));
            }
        }
    }

    // A full-canvas band is exactly the full blit.
    var whole = try Framebuffer.create(a, 8, 11, .xrgb8888, null);
    defer whole.destroy(a);
    whole.fill(0);
    blitViewportBand(whole, src, plan, 0, 8);
    try std.testing.expectEqualSlices(u8, full.mem, whole.mem);
}
