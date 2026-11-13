//! src/framebuffer.zig -- shared pixel types for every video backend and
//! renderer (contract file; drm2d/drm3d/fbdev back buffers and the CPU/GL
//! renderers all speak this vocabulary).
//!
//! Pixels are 32-bit little-endian words: xrgb8888 = 0xXXRRGGBB (DRM_FORMAT_
//! XRGB8888), argb8888 = 0xAARRGGBB (DRM_FORMAT_ARGB8888). Memory is row-major
//! with `pitch` bytes per row; the pitch may exceed width*4 (dumb-buffer
//! stride alignment), so every row access goes through the pitch.
//!
//! This file imports nothing outside std: it is the bottom of the contract
//! graph (video.zig, session.zig and render.zig all import it).

const std = @import("std");

/// Pixel formats shared by back buffers, cursor images and the renderer.
pub const PixelFormat = enum {
    xrgb8888,
    argb8888,

    pub fn bytesPerPixel(self: PixelFormat) u32 {
        return switch (self) {
            .xrgb8888, .argb8888 => 4,
        };
    }

    pub fn hasAlpha(self: PixelFormat) bool {
        return switch (self) {
            .xrgb8888 => false,
            .argb8888 => true,
        };
    }
};

/// Axis-aligned pixel rectangle, half-open: covers columns [x, x+w) and
/// rows [y, y+h). A zero width or height means empty.
pub const Damage = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn isEmpty(self: Damage) bool {
        return self.w == 0 or self.h == 0;
    }

    /// True when the two rectangles overlap in at least one pixel.
    /// Empty rectangles never intersect anything, including themselves.
    pub fn intersects(self: Damage, other: Damage) bool {
        return self.intersect(other) != null;
    }

    /// Smallest rectangle containing both (set union). Empty operands are
    /// ignored, so the union of two empties is empty and
    /// `boundingBox(a, empty) == a`. Named boundingBox because `union` is a
    /// Zig keyword.
    pub fn boundingBox(self: Damage, other: Damage) Damage {
        if (self.isEmpty()) return other;
        if (other.isEmpty()) return self;
        const x0 = @min(self.x, other.x);
        const y0 = @min(self.y, other.y);
        const x1 = @max(self.x + self.w, other.x + other.w);
        const y1 = @max(self.y + self.h, other.y + other.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// Overlap of the two rectangles, or null when they do not overlap.
    /// Never returns an empty rectangle.
    pub fn intersect(self: Damage, other: Damage) ?Damage {
        if (self.isEmpty() or other.isEmpty()) return null;
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x + self.w, other.x + other.w);
        const y1 = @min(self.y + self.h, other.y + other.h);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// Full-width span covering rows [y0, y1), for dirty-row rendering
    /// (libghostty reports dirty rows, not cells). y1 <= y0 yields an empty
    /// rectangle.
    pub fn fromRows(y0: u32, y1: u32, width: u32) Damage {
        if (y1 <= y0) return .{ .x = 0, .y = y0, .w = width, .h = 0 };
        return .{ .x = 0, .y = y0, .w = width, .h = y1 - y0 };
    }

    /// Clip against the bounds [0, width) x [0, height). Returns null when
    /// nothing remains. Used by Framebuffer.blitFrom and by renderers to
    /// trim damage to the visible surface.
    pub fn clipTo(self: Damage, width: u32, height: u32) ?Damage {
        return self.intersect(.{ .x = 0, .y = 0, .w = width, .h = height });
    }
};

/// A rectangle of pixels in CPU memory. The buffer is borrowed: the owner
/// (video backend, renderer scratch area, test) allocates and frees it;
/// Framebuffer never allocates.
pub const Framebuffer = struct {
    /// Pixel memory, 64-byte aligned so SIMD row copies can use aligned
    /// loads/stores. Length must be at least pitch * height.
    mem: []align(64) u8,
    width: u32,
    height: u32,
    /// Bytes per row. May exceed width * bytesPerPixel (stride padding).
    pitch: u32,
    format: PixelFormat,

    /// Allocate a zeroed framebuffer with an optional pitch override (pass
    /// null for the tight width*4 stride). The returned buffer owns its
    /// memory; free it with `destroy`.
    pub fn create(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        format: PixelFormat,
        pitch: ?u32,
    ) std.mem.Allocator.Error!Framebuffer {
        const bpp = format.bytesPerPixel();
        const stride = pitch orelse width * bpp;
        if (stride < width * bpp) return error.OutOfMemory;
        const len = @as(usize, stride) * @as(usize, height);
        const mem = try allocator.alignedAlloc(u8, .fromByteUnits(64), len);
        @memset(mem, 0);
        return .{
            .mem = mem,
            .width = width,
            .height = height,
            .pitch = stride,
            .format = format,
        };
    }

    /// Free a buffer made by `create`. Never call this on a backend-owned
    /// buffer obtained from video.Backend.beginFrame.
    pub fn destroy(self: *Framebuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.mem);
        self.* = undefined;
    }

    /// Read one pixel as a raw u32 word. Out-of-bounds reads are programmer
    /// errors (asserted in safe builds).
    pub fn get(self: Framebuffer, x: u32, y: u32) u32 {
        std.debug.assert(x < self.width and y < self.height);
        const off = self.offset(x, y);
        return std.mem.readInt(u32, self.mem[off..][0..4], .little);
    }

    /// Write one pixel as a raw u32 word. Out-of-bounds writes are
    /// programmer errors (asserted in safe builds).
    pub fn set(self: Framebuffer, x: u32, y: u32, color: u32) void {
        std.debug.assert(x < self.width and y < self.height);
        const off = self.offset(x, y);
        std.mem.writeInt(u32, self.mem[off..][0..4], color, .little);
    }

    /// Paint every pixel with `color`, honoring the pitch padding (padding
    /// bytes are left untouched).
    pub fn fill(self: Framebuffer, color: u32) void {
        const row_px = @as(usize, self.width);
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const bytes = self.row(y);
            var x: usize = 0;
            while (x < row_px) : (x += 1) {
                std.mem.writeInt(u32, bytes[x * 4 ..][0..4], color, .little);
            }
        }
    }

    /// Paint every pixel with `color`. Contract alias of `fill`, kept
    /// because backends and sessions spell the operation both ways.
    pub fn clear(self: Framebuffer, color: u32) void {
        self.fill(color);
    }

    /// Copy `src_rect` from `src` into `self` with its top-left corner at
    /// (dst_x, dst_y). The source rect is clipped to the source bounds, the
    /// result is clipped to the destination bounds; fully out-of-bounds
    /// blits are no-ops. Formats must match (words are copied verbatim;
    /// there is no alpha blending and no conversion). Negative destination
    /// coordinates clip the left/top edges.
    pub fn blitFrom(self: Framebuffer, src: Framebuffer, dst_x: i32, dst_y: i32, src_rect: Damage) void {
        std.debug.assert(self.format == src.format);
        const clipped = src_rect.clipTo(src.width, src.height) orelse return;

        // The clipped rect's top-left lands at (dst_x, dst_y). Work in i64
        // so negative dst coordinates and u32 extents cannot wrap.
        const dx0: i64 = dst_x;
        const dy0: i64 = dst_y;
        const dx1 = dx0 + @as(i64, clipped.w);
        const dy1 = dy0 + @as(i64, clipped.h);
        const cx0 = @max(dx0, 0);
        const cy0 = @max(dy0, 0);
        const cx1 = @min(dx1, @as(i64, self.width));
        const cy1 = @min(dy1, @as(i64, self.height));
        if (cx1 <= cx0 or cy1 <= cy0) return;

        // Source offset of the visible part: the clipped rect's origin
        // plus how far the destination clamp pushed past it.
        const sx0: u32 = @intCast(cx0 - dx0 + @as(i64, clipped.x));
        const sy0: u32 = @intCast(cy0 - dy0 + @as(i64, clipped.y));
        const w: usize = @intCast(cx1 - cx0);
        const h: usize = @intCast(cy1 - cy0);

        var i: usize = 0;
        while (i < h) : (i += 1) {
            const src_row = src.row(sy0 + @as(u32, @intCast(i)));
            const dst_row = self.row(@as(u32, @intCast(cy0)) + @as(u32, @intCast(i)));
            const src_off = @as(usize, sx0) * 4;
            const dst_off = @as(usize, @intCast(cx0)) * 4;
            @memcpy(dst_row[dst_off..][0 .. w * 4], src_row[src_off..][0 .. w * 4]);
        }
    }

    fn offset(self: Framebuffer, x: u32, y: u32) usize {
        return @as(usize, y) * @as(usize, self.pitch) + @as(usize, x) * 4;
    }

    fn row(self: Framebuffer, y: u32) []u8 {
        const start = @as(usize, y) * @as(usize, self.pitch);
        return self.mem[start..][0 .. @as(usize, self.width) * 4];
    }
};

test "PixelFormat: bytes per pixel and alpha" {
    try std.testing.expectEqual(@as(u32, 4), PixelFormat.xrgb8888.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 4), PixelFormat.argb8888.bytesPerPixel());
    try std.testing.expect(!PixelFormat.xrgb8888.hasAlpha());
    try std.testing.expect(PixelFormat.argb8888.hasAlpha());
}

test "Damage: union bounding box, including empty operands" {
    const a = Damage{ .x = 2, .y = 3, .w = 4, .h = 5 };
    const b = Damage{ .x = 10, .y = 1, .w = 2, .h = 2 };
    try std.testing.expectEqual(Damage{ .x = 2, .y = 1, .w = 10, .h = 7 }, a.boundingBox(b));
    try std.testing.expectEqual(a.boundingBox(b), b.boundingBox(a));

    // Overlapping rects: union is the bounding box, not the sum of areas.
    const c = Damage{ .x = 4, .y = 4, .w = 4, .h = 4 };
    try std.testing.expectEqual(Damage{ .x = 2, .y = 3, .w = 6, .h = 5 }, a.boundingBox(c));

    const empty = Damage{ .x = 7, .y = 7, .w = 0, .h = 9 };
    try std.testing.expect(empty.isEmpty());
    try std.testing.expectEqual(a, a.boundingBox(empty));
    try std.testing.expectEqual(a, empty.boundingBox(a));
    try std.testing.expect(empty.boundingBox(empty).isEmpty());
}

test "Damage: intersect overlap, touch and disjoint" {
    const a = Damage{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Damage{ .x = 5, .y = 5, .w = 10, .h = 10 };
    try std.testing.expect(a.intersects(b));
    try std.testing.expectEqual(Damage{ .x = 5, .y = 5, .w = 5, .h = 5 }, a.intersect(b).?);
    try std.testing.expectEqual(a.intersect(b), b.intersect(a));

    // Edge-touching rects share no pixel.
    const touch = Damage{ .x = 10, .y = 0, .w = 5, .h = 5 };
    try std.testing.expect(!a.intersects(touch));
    try std.testing.expectEqual(@as(?Damage, null), a.intersect(touch));

    const disjoint = Damage{ .x = 20, .y = 20, .w = 2, .h = 2 };
    try std.testing.expectEqual(@as(?Damage, null), a.intersect(disjoint));

    // Empty never intersects, even a rect containing its position.
    const empty = Damage{ .x = 1, .y = 1, .w = 0, .h = 3 };
    try std.testing.expect(!a.intersects(empty));
    try std.testing.expect(!empty.intersects(a));
    try std.testing.expect(!empty.intersects(empty));
}

test "Damage: fromRows spans and empty ranges" {
    try std.testing.expectEqual(
        Damage{ .x = 0, .y = 3, .w = 80, .h = 4 },
        Damage.fromRows(3, 7, 80),
    );
    try std.testing.expectEqual(
        Damage{ .x = 0, .y = 5, .w = 80, .h = 0 },
        Damage.fromRows(5, 5, 80),
    );
    try std.testing.expect(Damage.fromRows(9, 2, 80).isEmpty());
}

test "Damage: clipTo bounds, including fully out-of-bounds" {
    const d = Damage{ .x = 8, .y = 8, .w = 10, .h = 10 };
    try std.testing.expectEqual(Damage{ .x = 8, .y = 8, .w = 2, .h = 2 }, d.clipTo(10, 10).?);

    // Negative-side overflow: clip the origin.
    const big = Damage{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expectEqual(Damage{ .x = 0, .y = 0, .w = 10, .h = 10 }, big.clipTo(10, 10).?);

    try std.testing.expectEqual(@as(?Damage, null), (Damage{ .x = 10, .y = 0, .w = 4, .h = 4 }).clipTo(10, 10));
    try std.testing.expectEqual(@as(?Damage, null), (Damage{ .x = 0, .y = 10, .w = 4, .h = 4 }).clipTo(10, 10));
    try std.testing.expectEqual(@as(?Damage, null), (Damage{ .x = 9, .y = 9, .w = 0, .h = 4 }).clipTo(10, 10));
}

test "Framebuffer: set/get round-trip for both formats" {
    const a = std.testing.allocator;
    inline for (.{ PixelFormat.xrgb8888, PixelFormat.argb8888 }) |fmt| {
        var fb = try Framebuffer.create(a, 8, 6, fmt, null);
        defer fb.destroy(a);

        try std.testing.expectEqual(@as(u32, 32), fb.pitch);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(fb.mem.ptr) % 64);

        const colors = [_]u32{ 0x00000000, 0xFFFFFFFF, 0x12345678, 0x80FF00AA };
        for (colors, 0..) |color, i| {
            fb.set(@intCast(i), @intCast(i + 1), color);
        }
        for (colors, 0..) |color, i| {
            try std.testing.expectEqual(color, fb.get(@intCast(i), @intCast(i + 1)));
        }
        // Untouched pixels stay zero.
        try std.testing.expectEqual(@as(u32, 0), fb.get(7, 5));
    }
}

test "Framebuffer: fill and clear honor pitch padding" {
    const a = std.testing.allocator;
    // Pitch 40 for width 8: 8 padding bytes per row.
    var fb = try Framebuffer.create(a, 8, 4, .xrgb8888, 40);
    defer fb.destroy(a);

    // Poison the padding so a fill that ignores pitch would be caught.
    @memset(fb.mem, 0xEE);
    fb.fill(0xAABBCCDD);
    var y: u32 = 0;
    while (y < fb.height) : (y += 1) {
        var x: u32 = 0;
        while (x < fb.width) : (x += 1) {
            try std.testing.expectEqual(@as(u32, 0xAABBCCDD), fb.get(x, y));
        }
        const pad_start = @as(usize, y) * 40 + 32;
        for (fb.mem[pad_start..][0..8]) |byte| {
            try std.testing.expectEqual(@as(u8, 0xEE), byte);
        }
    }

    fb.clear(0x01020304);
    try std.testing.expectEqual(@as(u32, 0x01020304), fb.get(0, 0));
    try std.testing.expectEqual(@as(u32, 0x01020304), fb.get(7, 3));
}

test "Framebuffer: pitch greater than width*4 is respected by get/set" {
    const a = std.testing.allocator;
    var fb = try Framebuffer.create(a, 3, 3, .argb8888, 32);
    defer fb.destroy(a);

    fb.set(2, 2, 0xDEADBEEF);
    // Row 2 starts at byte 64; pixel x=2 sits 8 bytes in.
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), std.mem.readInt(u32, fb.mem[72..76], .little));
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), fb.get(2, 2));
    try std.testing.expectEqual(@as(u32, 0), fb.get(0, 2));
}

test "Framebuffer: blit clipping at all four edges" {
    const a = std.testing.allocator;
    var src = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer src.destroy(a);
    var dst = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer dst.destroy(a);

    // Distinct value per source pixel: (y << 8) | x, nonzero everywhere.
    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) {
            src.set(x, y, (y << 8) | x | 0x100);
        }
    }
    const whole = Damage{ .x = 0, .y = 0, .w = 4, .h = 4 };

    // Right edge: dst_x=2 keeps source columns 0..1 in dst columns 2..3.
    dst.clear(0);
    dst.blitFrom(src, 2, 0, whole);
    try std.testing.expectEqual(src.get(0, 0), dst.get(2, 0));
    try std.testing.expectEqual(src.get(1, 3), dst.get(3, 3));
    try std.testing.expectEqual(@as(u32, 0), dst.get(1, 0));

    // Bottom edge: dst_y=2 keeps source rows 0..1.
    dst.clear(0);
    dst.blitFrom(src, 0, 2, whole);
    try std.testing.expectEqual(src.get(0, 0), dst.get(0, 2));
    try std.testing.expectEqual(src.get(3, 1), dst.get(3, 3));
    try std.testing.expectEqual(@as(u32, 0), dst.get(0, 1));

    // Left edge: dst_x=-2 keeps source columns 2..3 in dst columns 0..1.
    dst.clear(0);
    dst.blitFrom(src, -2, 0, whole);
    try std.testing.expectEqual(src.get(2, 0), dst.get(0, 0));
    try std.testing.expectEqual(src.get(3, 3), dst.get(1, 3));
    try std.testing.expectEqual(@as(u32, 0), dst.get(2, 0));

    // Top edge: dst_y=-2 keeps source rows 2..3.
    dst.clear(0);
    dst.blitFrom(src, 0, -2, whole);
    try std.testing.expectEqual(src.get(0, 2), dst.get(0, 0));
    try std.testing.expectEqual(src.get(3, 3), dst.get(3, 1));
    try std.testing.expectEqual(@as(u32, 0), dst.get(0, 2));

    // All four edges at once: source rows/cols 1..3 land at dst 0..2.
    dst.clear(0);
    dst.blitFrom(src, -1, -1, whole);
    try std.testing.expectEqual(src.get(1, 1), dst.get(0, 0));
    try std.testing.expectEqual(src.get(3, 3), dst.get(2, 2));
    try std.testing.expectEqual(@as(u32, 0), dst.get(3, 0));
    try std.testing.expectEqual(@as(u32, 0), dst.get(0, 3));
}

test "Framebuffer: blit fully out-of-bounds and source-rect clipping" {
    const a = std.testing.allocator;
    var src = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer src.destroy(a);
    var dst = try Framebuffer.create(a, 4, 4, .xrgb8888, null);
    defer dst.destroy(a);
    src.fill(0x55AA55AA);
    dst.fill(0x11223344);
    const whole = Damage{ .x = 0, .y = 0, .w = 4, .h = 4 };

    // Fully off each edge: destination untouched.
    dst.blitFrom(src, 4, 0, whole);
    dst.blitFrom(src, -4, 0, whole);
    dst.blitFrom(src, 0, 4, whole);
    dst.blitFrom(src, 0, -4, whole);
    try std.testing.expectEqual(@as(u32, 0x11223344), dst.get(0, 0));
    try std.testing.expectEqual(@as(u32, 0x11223344), dst.get(3, 3));

    // Source rect larger than the source is clipped to the source first.
    dst.blitFrom(src, 0, 0, .{ .x = 2, .y = 2, .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(u32, 0x55AA55AA), dst.get(0, 0));
    try std.testing.expectEqual(@as(u32, 0x55AA55AA), dst.get(1, 1));
    try std.testing.expectEqual(@as(u32, 0x11223344), dst.get(2, 0));
    try std.testing.expectEqual(@as(u32, 0x11223344), dst.get(0, 2));

    // Empty source rect: no-op.
    dst.blitFrom(src, 0, 0, .{ .x = 0, .y = 0, .w = 0, .h = 4 });
    try std.testing.expectEqual(@as(u32, 0x11223344), dst.get(3, 3));
}

test "Framebuffer: blit with padded pitch on both sides" {
    const a = std.testing.allocator;
    var src = try Framebuffer.create(a, 3, 3, .argb8888, 32);
    defer src.destroy(a);
    var dst = try Framebuffer.create(a, 5, 5, .argb8888, 40);
    defer dst.destroy(a);

    var y: u32 = 0;
    while (y < 3) : (y += 1) {
        var x: u32 = 0;
        while (x < 3) : (x += 1) {
            src.set(x, y, 0xFF000000 | (y << 8) | x);
        }
    }
    dst.blitFrom(src, 1, 1, .{ .x = 0, .y = 0, .w = 3, .h = 3 });
    y = 0;
    while (y < 3) : (y += 1) {
        var x: u32 = 0;
        while (x < 3) : (x += 1) {
            try std.testing.expectEqual(src.get(x, y), dst.get(x + 1, y + 1));
        }
    }
    try std.testing.expectEqual(@as(u32, 0), dst.get(0, 0));
    try std.testing.expectEqual(@as(u32, 0), dst.get(4, 4));
}
