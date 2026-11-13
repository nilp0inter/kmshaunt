//! Tests for `src/misc/spng_decode.zig` (ROADMAP M4.1), plus the repository-root
//! test harness those tests need.
//!
//! Zig 0.17 confines `@import` to the root module's directory, and it resolves
//! imports even in unreachable branches. A test block inside
//! `src/misc/spng_decode.zig` therefore could not use `tools/png.zig`: the
//! project compiles that file from a root under `src/`, where `../../tools/`
//! is rejected at AstGen time ("import of file outside module path"). This
//! file sits at the repository root — the common ancestor of `src/` and
//! `tools/` — so it can import both and host the tests:
//!
//! ```
//! nix run nixpkgs#zig -- test test_spng.zig -lc -lspng -lghostty-vt
//! ```
//!
//! (`-L`/`LD_LIBRARY_PATH` are only needed if libspng or libghostty-vt are not
//! on the default search path; Zig records an rpath for `-L` directories.)
//!
//! The tests stand in for libghostty-vt: they install a tracking allocator
//! vtable, call the decoder in both its Zig and C-ABI forms, and free every
//! successful decode's pixels the way the library would.

const std = @import("std");
const png = @import("tools/png.zig");
const spng = @import("src/misc/spng_decode.zig");

const testing = std.testing;

/// Counterpart of the `ghostty_alloc` the decoder calls. Declared here rather
/// than reached through the module so the test also proves the exported C
/// symbol and ABI; `spng.GhosttyAllocatorView` is the module's mirror of the
/// C `GhosttyAllocator`.
extern fn ghostty_free(allocator: ?*const spng.GhosttyAllocatorView, ptr: ?[*]u8, len: usize) void;

/// Offset of a PNG chunk's payload, scanning from the front of the file. Used
/// to corrupt exactly one field while leaving the chunk framing intact.
fn chunkPayloadOffset(file: []const u8, kind: *const [4]u8) ?usize {
    const signature = "\x89PNG\r\n\x1a\n";
    var i: usize = signature.len;
    while (i + 12 <= file.len) {
        const len = std.mem.readInt(u32, file[i..][0..4], .big);
        if (std.mem.eql(u8, file[i + 4 ..][0..4], kind)) return i + 8;
        i += 12 + len;
    }
    return null;
}

/// Test allocator implementing the ghostty C vtable and tracking balance.
/// Every allocation is expected to be freed exactly once, either by the test
/// (successful decode) or by `decodePng` (failed decode).
const TestAllocator = struct {
    allocs: usize = 0,
    frees: usize = 0,
    live_bytes: usize = 0,
    fail: bool = false,

    const vtable: spng.AllocatorVtable = .{
        .alloc = allocFn,
        .resize = null,
        .remap = null,
        .free = freeFn,
        .reserved = .{ null, null, null, null },
    };

    fn view(self: *TestAllocator) spng.GhosttyAllocatorView {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn alignment(log2_alignment: u8) std.mem.Alignment {
        return @enumFromInt(@as(std.math.Log2Int(usize), @intCast(log2_alignment)));
    }

    fn allocFn(ctx: ?*anyopaque, len: usize, log2_alignment: u8, ret_addr: usize) callconv(.c) ?*anyopaque {
        const self: *TestAllocator = @ptrCast(@alignCast(ctx orelse return null));
        if (self.fail) return null;

        const memory = std.heap.c_allocator.rawAlloc(len, alignment(log2_alignment), ret_addr) orelse return null;
        self.allocs += 1;
        self.live_bytes += len;
        return @ptrCast(memory);
    }

    fn freeFn(ctx: ?*anyopaque, memory: ?*anyopaque, memory_len: usize, log2_alignment: u8, ret_addr: usize) callconv(.c) void {
        const self: *TestAllocator = @ptrCast(@alignCast(ctx orelse return));
        const ptr: [*]u8 = @ptrCast(memory orelse return);

        std.heap.c_allocator.rawFree(ptr[0..memory_len], alignment(log2_alignment), ret_addr);
        self.frees += 1;
        self.live_bytes -= memory_len;
    }

    fn expectBalanced(self: *const TestAllocator) !void {
        try testing.expectEqual(self.allocs, self.frees);
        try testing.expectEqual(@as(usize, 0), self.live_bytes);
    }
};

/// Stands in for libghostty-vt taking ownership of a decoded image.
fn freePixels(view: spng.GhosttyAllocatorView, out: *const spng.SysImage) void {
    ghostty_free(&view, out.data, out.data_len);
}

test "round trip: 3x2 RGBA decodes byte for byte" {
    const pixels = [_]u8{
        0x11, 0x22, 0x33, 0xff, 0x44, 0x55, 0x66, 0x80, 0x77, 0x88, 0x99, 0x00,
        0xaa, 0xbb, 0xcc, 0x7f, 0xdd, 0xee, 0x01, 0x40, 0x02, 0x03, 0x04, 0xc0,
    };
    const file = try png.encodePng(testing.allocator, .{
        .width = 3,
        .height = 2,
        .format = .rgba32,
        .pixels = &pixels,
    });
    defer testing.allocator.free(file);

    var tracked: TestAllocator = .{};
    const view = tracked.view();
    var out: spng.SysImage = .{};
    try testing.expect(spng.decodePng(file, view, &out));

    try testing.expectEqual(@as(u32, 3), out.width);
    try testing.expectEqual(@as(u32, 2), out.height);
    try testing.expectEqual(pixels.len, out.data_len);
    try testing.expect(out.data != null);
    try testing.expectEqualSlices(u8, &pixels, out.data.?[0..out.data_len]);

    // Exactly one ghostty_alloc: the pixel buffer.
    try testing.expectEqual(@as(usize, 1), tracked.allocs);
    try testing.expectEqual(pixels.len, tracked.live_bytes);

    // The library frees the buffer on success; the test stands in for it.
    freePixels(view, &out);
    try tracked.expectBalanced();
}

test "C callback ABI decodes the same bytes" {
    const pixels = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const file = try png.encodePng(testing.allocator, .{
        .width = 1,
        .height = 2,
        .format = .rgba32,
        .pixels = &pixels,
    });
    defer testing.allocator.free(file);

    var tracked: TestAllocator = .{};
    const view = tracked.view();
    var out: spng.SysImage = .{};
    try testing.expect(spng.decodePngCallback(null, &view, file.ptr, file.len, &out));

    try testing.expectEqual(@as(u32, 1), out.width);
    try testing.expectEqual(@as(u32, 2), out.height);
    try testing.expectEqualSlices(u8, &pixels, out.data.?[0..out.data_len]);

    freePixels(view, &out);
    try tracked.expectBalanced();
}

/// 2x1 truecolor PNG with a `tRNS` chunk for R,G,B = 10,20,30. `tools/png.zig`
/// never writes ancillary chunks (deterministic goldens), so this blob is
/// generated once and pinned here: 8-byte signature, IHDR (2x1, depth 8, color
/// type 2), tRNS (000a 0014 001e), one IDAT with the filtered row
/// `00 0a 14 1e 01 02 03` deflated, IEND. Its CRCs and zlib Adler-32 are
/// verified by libspng when the test decodes it.
const trns_png = [90]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x7b, 0x40, 0xe8, 0xdd, 0x00, 0x00, 0x00,
    0x06, 0x74, 0x52, 0x4e, 0x53, 0x00, 0x0a, 0x00, 0x14, 0x00, 0x1e, 0xc5,
    0x36, 0x29, 0xff, 0x00, 0x00, 0x00, 0x0f, 0x49, 0x44, 0x41, 0x54, 0x78,
    0xda, 0x63, 0xe0, 0x12, 0x91, 0x63, 0x64, 0x62, 0x06, 0x00, 0x01, 0x29,
    0x00, 0x43, 0x39, 0xe1, 0x51, 0x13, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

test "tRNS transparency is applied" {
    // The first pixel exactly matches tRNS, so it is fully transparent; the
    // second keeps alpha 255. Without SPNG_DECODE_TRNS the first would come
    // back opaque, which is what this test pins.
    var tracked: TestAllocator = .{};
    const view = tracked.view();
    var out: spng.SysImage = .{};
    try testing.expect(spng.decodePng(&trns_png, view, &out));

    const expected = [_]u8{ 10, 20, 30, 0, 1, 2, 3, 255 };
    try testing.expectEqual(@as(u32, 2), out.width);
    try testing.expectEqual(@as(u32, 1), out.height);
    try testing.expectEqual(@as(usize, expected.len), out.data_len);
    try testing.expectEqualSlices(u8, &expected, out.data.?[0..out.data_len]);

    freePixels(view, &out);
    try tracked.expectBalanced();
}

test "grayscale input is converted to opaque RGBA" {
    const pixels = [_]u8{ 0x00, 0x7f, 0xff, 0x42 };
    const file = try png.encodePng(testing.allocator, .{
        .width = 2,
        .height = 2,
        .format = .gray8,
        .pixels = &pixels,
    });
    defer testing.allocator.free(file);

    var tracked: TestAllocator = .{};
    const view = tracked.view();
    var out: spng.SysImage = .{};
    try testing.expect(spng.decodePng(file, view, &out));

    const expected = [_]u8{
        0x00, 0x00, 0x00, 0xff,
        0x7f, 0x7f, 0x7f, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0x42, 0x42, 0x42, 0xff,
    };
    try testing.expectEqualSlices(u8, &expected, out.data.?[0..out.data_len]);

    freePixels(view, &out);
    try tracked.expectBalanced();
}

test "corrupt input fails, frees everything, and leaves out untouched" {
    const pixels = [_]u8{ 1, 2, 3, 4 };
    const file = try png.encodePng(testing.allocator, .{
        .width = 1,
        .height = 1,
        .format = .rgba32,
        .pixels = &pixels,
    });
    defer testing.allocator.free(file);

    // Corrupt the zlib header inside IDAT: the IHDR still parses, so the
    // pixel buffer is allocated and then freed on decode failure.
    const corrupt = try testing.allocator.dupe(u8, file);
    defer testing.allocator.free(corrupt);
    const idat = chunkPayloadOffset(corrupt, "IDAT").?;
    corrupt[idat] ^= 0xff;

    var tracked: TestAllocator = .{};
    const view = tracked.view();
    var out: spng.SysImage = .{};
    try testing.expect(!spng.decodePng(corrupt, view, &out));
    try testing.expectEqual(@as(usize, 0), tracked.live_bytes);
    try testing.expectEqual(tracked.allocs, tracked.frees);
    try testing.expectEqual(@as(usize, 0), out.data_len);
    try testing.expect(out.data == null);

    // A file truncated inside IHDR never reaches an allocation.
    var trunc_tracked: TestAllocator = .{};
    try testing.expect(!spng.decodePng(file[0..20], trunc_tracked.view(), &out));
    try testing.expectEqual(@as(usize, 0), trunc_tracked.allocs);
    try trunc_tracked.expectBalanced();

    // Truncation after a valid IHDR allocates and then frees on decode error.
    var half_tracked: TestAllocator = .{};
    try testing.expect(!spng.decodePng(file[0 .. file.len / 2], half_tracked.view(), &out));
    try testing.expectEqual(half_tracked.allocs, half_tracked.frees);
    try half_tracked.expectBalanced();

    // Garbage that is not a PNG at all.
    var garbage_tracked: TestAllocator = .{};
    try testing.expect(!spng.decodePng("not a png", garbage_tracked.view(), &out));
    try testing.expectEqual(@as(usize, 0), garbage_tracked.allocs);
    try garbage_tracked.expectBalanced();
}

test "oversized dimensions are rejected before allocation" {
    const width = spng.Limits.max_dimension + 1;
    const pixels = try testing.allocator.alloc(u8, @as(usize, width) * 4);
    defer testing.allocator.free(pixels);
    @memset(pixels, 0xff);

    const file = try png.encodePng(testing.allocator, .{
        .width = width,
        .height = 1,
        .format = .rgba32,
        .pixels = pixels,
    });
    defer testing.allocator.free(file);

    var tracked: TestAllocator = .{};
    var out: spng.SysImage = .{};
    try testing.expect(!spng.decodePng(file, tracked.view(), &out));
    try testing.expectEqual(@as(usize, 0), tracked.allocs);
    try tracked.expectBalanced();
}

test "a failing allocator is a decode failure, not a leak" {
    const pixels = [_]u8{ 9, 8, 7, 6 };
    const file = try png.encodePng(testing.allocator, .{
        .width = 1,
        .height = 1,
        .format = .rgba32,
        .pixels = &pixels,
    });
    defer testing.allocator.free(file);

    var tracked: TestAllocator = .{ .fail = true };
    var out: spng.SysImage = .{};
    try testing.expect(!spng.decodePng(file, tracked.view(), &out));
    try testing.expectEqual(@as(usize, 0), tracked.allocs);
    try tracked.expectBalanced();
}

test "empty and malformed pointer input is rejected" {
    var tracked: TestAllocator = .{};
    const view = tracked.view();
    var out: spng.SysImage = .{};

    try testing.expect(!spng.decodePng(&.{}, view, &out));
    try testing.expect(!spng.decodePngCallback(null, &view, null, 0, &out));
    try testing.expect(!spng.decodePngCallback(null, &view, null, 4, &out));
    try testing.expect(!spng.decodePngCallback(null, null, null, 0, &out));
    try tracked.expectBalanced();
}

/// The same C symbol `spng.install()` uses, declared here so the test can also
/// pass NULL and clear the process-global setting again.
extern fn ghostty_sys_set(option: c_int, value: ?*const anyopaque) c_int;

/// C: `GHOSTTY_SYS_OPT_DECODE_PNG` (sys.h:229).
const option_decode_png: c_int = 2;

test "install() registers through ghostty_sys_set" {
    spng.install();

    // Clearing proves the option is live in this library build; reinstalling
    // leaves the process the way a real startup would.
    try testing.expectEqual(@as(c_int, 0), ghostty_sys_set(option_decode_png, null));
    spng.install();
    try testing.expectEqual(@as(c_int, 0), ghostty_sys_set(option_decode_png, null));
}

/// The handful of libghostty-vt C entry points the end-to-end test needs. These
/// mirror `terminal.h` and `kitty_graphics.h` the same way the module mirrors
/// `sys.h`; the handles are opaque pointers.
const LibVt = struct {
    /// C: `GhosttyTerminal` (`struct GhosttyTerminalImpl*`).
    const Terminal = ?*anyopaque;
    /// C: `GhosttyKittyGraphics`.
    const Graphics = ?*anyopaque;
    /// C: `GhosttyKittyGraphicsImage`.
    const Image = ?*anyopaque;

    /// C: `GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS`.
    const terminal_data_kitty_graphics: c_int = 30;
    /// C: `GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH`.
    const image_data_width: c_int = 3;
    /// C: `GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT`.
    const image_data_height: c_int = 4;

    extern fn ghostty_terminal_new(allocator: ?*const spng.GhosttyAllocatorView, terminal: *Terminal, cols: u16, rows: u16) c_int;
    extern fn ghostty_terminal_free(terminal: Terminal) void;
    extern fn ghostty_terminal_vt_write(terminal: Terminal, data: [*]const u8, len: usize) void;
    extern fn ghostty_terminal_get(terminal: Terminal, data: c_int, out: *anyopaque) c_int;
    extern fn ghostty_kitty_graphics_image(graphics: Graphics, image_id: u32) Image;
    extern fn ghostty_kitty_graphics_image_get(image: Image, data: c_int, out: *anyopaque) c_int;
};

test "installed callback decodes a Kitty graphics PNG end to end" {
    const pixels = [_]u8{
        0x10, 0x20, 0x30, 0xff, 0x40, 0x50, 0x60, 0xff, 0x70, 0x80, 0x90, 0xff,
        0xa0, 0xb0, 0xc0, 0xff, 0xd0, 0xe0, 0xf0, 0xff, 0x01, 0x02, 0x03, 0xff,
    };
    const file = try png.encodePng(testing.allocator, .{
        .width = 3,
        .height = 2,
        .format = .rgba32,
        .pixels = &pixels,
    });
    defer testing.allocator.free(file);

    spng.install();

    var terminal: LibVt.Terminal = null;
    try testing.expectEqual(@as(c_int, 0), LibVt.ghostty_terminal_new(null, &terminal, 80, 24));
    defer LibVt.ghostty_terminal_free(terminal);

    // Kitty graphics APC: transmit and display (`a=T`) a PNG (`f=100`) under
    // image id 1, quiet (`q=2`), payload base64-encoded. ESC _ G ... ESC \\.
    const encoded_len = std.base64.standard.Encoder.calcSize(file.len);
    const encoded = try testing.allocator.alloc(u8, encoded_len);
    defer testing.allocator.free(encoded);
    const payload = std.base64.standard.Encoder.encode(encoded, file);

    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(testing.allocator);
    try command.appendSlice(testing.allocator, "\x1b_Ga=T,f=100,i=1,q=2;");
    try command.appendSlice(testing.allocator, payload);
    try command.appendSlice(testing.allocator, "\x1b\\");
    LibVt.ghostty_terminal_vt_write(terminal, command.items.ptr, command.items.len);

    var graphics: LibVt.Graphics = null;
    const rc = LibVt.ghostty_terminal_get(terminal, LibVt.terminal_data_kitty_graphics, @ptrCast(&graphics));
    if (rc == -8) return error.SkipZigTest; // GHOSTTY_UNSUPPORTED: built without kitty graphics
    try testing.expectEqual(@as(c_int, 0), rc);

    const image = LibVt.ghostty_kitty_graphics_image(graphics, 1) orelse
        return error.TestUnexpectedResult; // the PNG was not decoded, so install() is not wired

    var width: u32 = 0;
    var height: u32 = 0;
    try testing.expectEqual(@as(c_int, 0), LibVt.ghostty_kitty_graphics_image_get(image, LibVt.image_data_width, @ptrCast(&width)));
    try testing.expectEqual(@as(c_int, 0), LibVt.ghostty_kitty_graphics_image_get(image, LibVt.image_data_height, @ptrCast(&height)));
    try testing.expectEqual(@as(u32, 3), width);
    try testing.expectEqual(@as(u32, 2), height);

    _ = ghostty_sys_set(option_decode_png, null);
}