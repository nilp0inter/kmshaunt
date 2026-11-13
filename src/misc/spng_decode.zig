//! libspng-backed PNG decoder for libghostty-vt (ROADMAP M4.1, spike Q2).
//!
//! libghostty-vt ships no PNG decoder. Embedders install one through the
//! process-global `GHOSTTY_SYS_OPT_DECODE_PNG` hook (`sys.h`); without it, the
//! Kitty Graphics Protocol works but rejects PNG image data. This module is
//! kmshaunt's implementation, backed by libspng 0.7. Call [`install`] once, at
//! startup, single-threaded, before any terminal object exists or any other
//! thread touches the library (`ghostty_sys_set` is documented as not
//! thread-safe; see `sys.h:22-25`).
//!
//! # The contract (docs/spikes/q2-libspng.md §1, sys.h:43-182)
//!
//! The library zeroes `out` before calling the callback and then:
//!
//! * buffers are 8-bit RGBA, four bytes per pixel, rows top-down from the
//!   top-left, no padding, so exactly `width * height * 4` bytes;
//! * the pixel buffer must be allocated with the allocator passed in, through
//!   `ghostty_alloc`, and freed with `ghostty_free`;
//! * on `true`, the library takes ownership of `data` and later frees it with
//!   the same allocator; `data_len` must be the exact size that was requested
//!   from the allocator (`sys.h:122-128`);
//! * on `false`, the callback frees everything it allocated and the library
//!   does not read `out` (`sys.h:134-137`);
//! * a failed `ghostty_alloc` (NULL, e.g. over the 400 MB per-image cap) is a
//!   failure, not an empty image (`sys.h:130-132`).
//!
//! libspng's one-shot `spng_decode_image(..., SPNG_FMT_RGBA8, ...)` writes
//! exactly that layout into a caller-supplied buffer, so the callback decodes
//! straight into the ghostty-owned allocation: no staging buffer, no row
//! stride fix-up, no copy. `SPNG_DECODE_TRNS` is passed so `tRNS` transparency
//! is applied (opt-in in libspng 0.7); `SPNG_DECODE_GAMMA` is not, because
//! ghostty's reference decoder ignores `gAMA` and the C API contract promises
//! plain RGBA.
//!
//! # Hardening (R3: this decoder runs on untrusted input in a root process)
//!
//! Limits are installed on the decoder context *before* the first parse
//! (`spng_get_ihdr` / `spng_decoded_image_size` trigger it lazily), and no
//! pixel buffer exists until the decoded size has been checked:
//!
//! | knob | value | effect |
//! |---|---|---|
//! | `spng_set_image_limits` | [`Limits.max_dimension`] (10000) | rejects `SPNG_EUSER_WIDTH`/`SPNG_EUSER_HEIGHT` at IHDR parse, mirroring the terminal's own `max_dimension` |
//! | `spng_set_chunk_limits` | 8 MiB per chunk, 32 MiB ancillary cache | caps decompression-bomb and huge-text-chunk DoS |
//! | decoded size | [`Limits.max_decoded_bytes`] (400 MiB) | belt and braces under the terminal's per-image allocator cap |
//! | CRC / Adler-32 | verification left on | no `SPNG_CTX_IGNORE_ADLER32`, no `SPNG_CRC_USE` |
//!
//! `spng_ctx_new(0)` also keeps libspng's default chunk-count limit (1000) and
//! its malloc-backed internal state, which is small and bounded by the limits
//! above.
//!
//! A context is created and freed per callback invocation: `spng_decode_image`
//! is one-shot, and per-invocation contexts make the callback safe to call
//! from any of the terminal's threads.
//!
//! # C ABI
//!
//! Everything below the public API is a hand-pruned `translate-c` of
//! libspng 0.7.4 `spng.h` and libghostty-vt 1.0.1 `sys.h` / `allocator.h` /
//! `types.h`. Keeping the declarations here means the rest of the tree never
//! sees a C type and this module only needs `-lspng` and the ghostty-vt
//! library at link time. The declarations are pinned by the `comptime` layout
//! assertions and exercised against the real libraries by the tests; re-check
//! them when either version is bumped.
//!
//! # Testing
//!
//! The tests live in `test_spng.zig` at the repository root. Zig 0.17 confines
//! `@import` to the root module's directory and resolves imports even in
//! unreachable branches, so a test block here could not import
//! `tools/png.zig`: the project compiles this file from a root under `src/`,
//! where `../../tools/` is rejected at AstGen time. The repository-root
//! harness — the common ancestor of `src/` and `tools/` — can import both:
//!
//! ```
//! nix run nixpkgs#zig -- test test_spng.zig -lc -lspng -lghostty-vt
//! ```

const std = @import("std");

/// Decoder limits. See the module docs for why each one exists and where it
/// comes from. They are compile-time constants so the hostile-input path costs
/// nothing at run time.
pub const Limits = struct {
    /// Largest accepted width or height, in pixels. Mirrors the terminal's own
    /// `max_dimension` (`graphics_image.zig:20`); libspng rejects anything
    /// larger at IHDR parse, before allocating.
    pub const max_dimension: u32 = 10_000;

    /// Largest accepted PNG chunk payload (8 MiB) and ancillary-chunk cache
    /// (32 MiB), per libspng's "decoding untrusted files" guidance.
    pub const max_chunk_size: usize = 8 * 1024 * 1024;
    pub const max_cache_size: usize = 32 * 1024 * 1024;

    /// Largest decoded RGBA8 image (400 MiB), mirroring the `LimitedAllocator`
    /// cap libghostty-vt wraps around the callback's allocator. A legal
    /// 10000x10000 image is 400,000,000 bytes, so this never rejects an image
    /// the dimension limit allows; it is the backstop if the limits are ever
    /// raised independently.
    pub const max_decoded_bytes: usize = 400 * 1024 * 1024;
};

// ---------------------------------------------------------------------------
// C ABI: libspng 0.7.4 (spng.h)
// ---------------------------------------------------------------------------

/// C: `spng_ctx` (opaque).
const SpngContext = opaque {};

/// C: `struct spng_ihdr` (spng.h:221-227). Five `uint8_t` fields follow two
/// `uint32_t`s, so the C struct is 16 bytes with 3 bytes of tail padding.
const SpngIhdr = extern struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,
};

/// C: `SPNG_FMT_RGBA8` (spng.h:170). Byte-order R,G,B,A, host-endian, packed.
const SPNG_FMT_RGBA8: c_int = 1;
/// C: `SPNG_DECODE_TRNS` (spng.h:196). Apply `tRNS` transparency.
const SPNG_DECODE_TRNS: c_int = 1;
/// C: `SPNG_OK` (spng.h:34). Every error code is positive.
const SPNG_OK: c_int = 0;

extern fn spng_ctx_new(flags: c_int) ?*SpngContext;
extern fn spng_ctx_free(ctx: ?*SpngContext) void;
extern fn spng_set_png_buffer(ctx: *SpngContext, buf: [*]const u8, size: usize) c_int;
extern fn spng_set_image_limits(ctx: *SpngContext, width: u32, height: u32) c_int;
extern fn spng_set_chunk_limits(ctx: *SpngContext, chunk_size: usize, cache_size: usize) c_int;
extern fn spng_get_ihdr(ctx: *SpngContext, ihdr: *SpngIhdr) c_int;
extern fn spng_decoded_image_size(ctx: *SpngContext, fmt: c_int, len: *usize) c_int;
extern fn spng_decode_image(ctx: *SpngContext, out: ?[*]u8, len: usize, fmt: c_int, flags: c_int) c_int;

// ---------------------------------------------------------------------------
// C ABI: libghostty-vt 1.0.1 (sys.h, allocator.h, types.h)
// ---------------------------------------------------------------------------

/// C: `GhosttySysImage` (sys.h:55-73).
pub const SysImage = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    data: ?[*]u8 = null,
    data_len: usize = 0,
};

/// C: `GhosttyAllocatorAllocFn` (allocator.h:43). `alignment` is a log2 byte
/// alignment, i.e. the block must be aligned to `1 << alignment`.
pub const AllocFn = *const fn (ctx: ?*anyopaque, len: usize, alignment: u8, ret_addr: usize) callconv(.c) ?*anyopaque;
/// C: `GhosttyAllocatorResizeFn` (allocator.h:78).
pub const ResizeFn = *const fn (ctx: ?*anyopaque, memory: ?*anyopaque, memory_len: usize, alignment: u8, new_len: usize, ret_addr: usize) callconv(.c) bool;
/// C: `GhosttyAllocatorRemapFn` (allocator.h:105).
pub const RemapFn = *const fn (ctx: ?*anyopaque, memory: ?*anyopaque, memory_len: usize, alignment: u8, new_len: usize, ret_addr: usize) callconv(.c) ?*anyopaque;
/// C: `GhosttyAllocatorFreeFn` (allocator.h:133).
pub const FreeFn = *const fn (ctx: ?*anyopaque, memory: ?*anyopaque, memory_len: usize, alignment: u8, ret_addr: usize) callconv(.c) void;

/// C: `GhosttyAllocatorVtable` (allocator.h:179-198). `alloc` and `free` are
/// required; `resize`/`remap` may be null; `reserved` must be null.
pub const AllocatorVtable = extern struct {
    alloc: AllocFn,
    resize: ?ResizeFn,
    remap: ?RemapFn,
    free: FreeFn,
    reserved: [4]?*anyopaque = @splat(null),
};

/// C: `GhosttyAllocator` (allocator.h:210-224): the allocator the library
/// hands to the decode callback. Use it only through `ghostty_alloc` /
/// `ghostty_free`; the vtable is opaque by contract (`sys.h:165-166`).
pub const GhosttyAllocatorView = extern struct {
    ctx: ?*anyopaque,
    vtable: *const AllocatorVtable,
};

/// C: `GHOSTTY_SYS_OPT_DECODE_PNG` (sys.h:229).
const GHOSTTY_SYS_OPT_DECODE_PNG: c_int = 2;
/// C: `GHOSTTY_SUCCESS` (types.h:165).
const GHOSTTY_SUCCESS: c_int = 0;

extern fn ghostty_alloc(allocator: ?*const GhosttyAllocatorView, len: usize) ?[*]u8;
extern fn ghostty_free(allocator: ?*const GhosttyAllocatorView, ptr: ?[*]u8, len: usize) void;
extern fn ghostty_sys_set(option: c_int, value: ?*const anyopaque) c_int;

/// C: `GhosttySysDecodePngFn` (sys.h:177-182). This is the exact callback ABI
/// the library calls: `userdata`, the allocator for the output pixels, the raw
/// PNG bytes, and a zeroed `out` that the callback fills on success.
pub const DecodePngFn = *const fn (
    userdata: ?*anyopaque,
    allocator: ?*const GhosttyAllocatorView,
    data: ?[*]const u8,
    data_len: usize,
    out: *SysImage,
) callconv(.c) bool;

comptime {
    // Pin the hand-translated C layouts. If any of these change, the shims
    // above no longer match the libraries they claim to bind. @compileError
    // (not assert) so the check also fires in ReleaseFast and ReleaseSmall.
    if (@sizeOf(SpngIhdr) != 16) @compileError("spng_ihdr layout changed");
    if (@offsetOf(SpngIhdr, "width") != 0) @compileError("spng_ihdr.width moved");
    if (@offsetOf(SpngIhdr, "height") != 4) @compileError("spng_ihdr.height moved");
    if (@offsetOf(SpngIhdr, "bit_depth") != 8) @compileError("spng_ihdr.bit_depth moved");
    if (@offsetOf(SpngIhdr, "color_type") != 9) @compileError("spng_ihdr.color_type moved");
    if (@sizeOf(GhosttyAllocatorView) != 2 * @sizeOf(?*anyopaque)) @compileError("GhosttyAllocator layout changed");
    if (@offsetOf(GhosttyAllocatorView, "ctx") != 0) @compileError("GhosttyAllocator.ctx moved");
    if (@offsetOf(GhosttyAllocatorView, "vtable") != @sizeOf(?*anyopaque)) @compileError("GhosttyAllocator.vtable moved");
    if (@sizeOf(SysImage) != 8 + 2 * @sizeOf(usize)) @compileError("GhosttySysImage layout changed");
    if (@offsetOf(SysImage, "width") != 0) @compileError("GhosttySysImage.width moved");
    if (@offsetOf(SysImage, "height") != 4) @compileError("GhosttySysImage.height moved");
    // The library frees `data` with the allocator it passed in, so the size
    // it records must be the size we requested.
    if (@offsetOf(SysImage, "data") != 8) @compileError("GhosttySysImage.data moved");
    if (@offsetOf(SysImage, "data_len") != 8 + @sizeOf(?*anyopaque)) @compileError("GhosttySysImage.data_len moved");
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Installs the decoder process-globally.
///
/// `ghostty_sys_set` is not thread-safe and the setting is global, so call
/// this once during single-threaded startup, before creating a terminal or
/// starting any thread that uses libghostty-vt. Calling it again is harmless
/// but unnecessary. The callback needs no userdata.
pub fn install() void {
    _ = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, @ptrCast(&decodePngCallback));
}

/// Decodes a PNG into RGBA8 pixels for libghostty-vt.
///
/// On success fills `out` with the exact `width * height * 4` pixel buffer,
/// allocated through `alloc` (never libc `malloc`), and returns `true`; the
/// caller then owns the buffer and must free it with `ghostty_free` and the
/// same allocator — which is what the library does when this runs as the
/// installed callback. On any failure nothing is left allocated, nothing is
/// written to `out`, and `false` is returned.
pub fn decodePng(png: []const u8, alloc: GhosttyAllocatorView, out: *SysImage) bool {
    if (png.len == 0) return false;

    // One context per invocation: `spng_decode_image` is one-shot, and this
    // keeps the callback free of shared mutable state.
    const ctx = spng_ctx_new(0) orelse return false;
    defer spng_ctx_free(ctx);

    // R3: hardening before the first parse. IHDR is parsed lazily by the
    // first spng_get_ihdr / spng_decoded_image_size, so these must be set
    // before either call.
    if (spng_set_image_limits(ctx, Limits.max_dimension, Limits.max_dimension) != SPNG_OK) return false;
    if (spng_set_chunk_limits(ctx, Limits.max_chunk_size, Limits.max_cache_size) != SPNG_OK) return false;
    if (spng_set_png_buffer(ctx, png.ptr, png.len) != SPNG_OK) return false;

    var ihdr: SpngIhdr = undefined;
    if (spng_get_ihdr(ctx, &ihdr) != SPNG_OK) return false;
    if (!headerIsValid(&ihdr)) return false;

    var out_len: usize = 0;
    if (spng_decoded_image_size(ctx, SPNG_FMT_RGBA8, &out_len) != SPNG_OK) return false;

    // The C contract is byte-exact: `data_len` must be the size requested from
    // the allocator, and the buffer must be width*height*4. Recomputing it
    // from IHDR also catches any disagreement before an allocation happens,
    // and the explicit cap backstops the dimension limit.
    const pixel_count = std.math.mul(usize, ihdr.width, ihdr.height) catch return false;
    const expected_len = std.math.mul(usize, pixel_count, 4) catch return false;
    if (out_len != expected_len) return false;
    if (out_len == 0 or out_len > Limits.max_decoded_bytes) return false;

    // Output pixels come from the library's allocator, never libc; a NULL
    // result (over the per-image cap) is a decode failure, not an empty image.
    const pixels = ghostty_alloc(&alloc, out_len) orelse return false;

    // Decode straight into the ghostty-owned buffer: SPNG_FMT_RGBA8 is
    // byte-identical to the GhosttySysImage layout (Q2 §3/§5).
    if (spng_decode_image(ctx, pixels, out_len, SPNG_FMT_RGBA8, SPNG_DECODE_TRNS) != SPNG_OK) {
        ghostty_free(&alloc, pixels, out_len);
        return false;
    }

    out.* = .{
        .width = ihdr.width,
        .height = ihdr.height,
        .data = pixels,
        .data_len = out_len,
    };
    return true;
}

/// C-ABI trampoline handed to `ghostty_sys_set`. Adapts the C signature to
/// [`decodePng`] and turns the C pointer/length pair into a slice.
///
/// Public so tests (and embedders wiring the hook by hand) can call the exact
/// [`DecodePngFn`] ABI without going through `install`.
pub fn decodePngCallback(
    userdata: ?*anyopaque,
    allocator: ?*const GhosttyAllocatorView,
    data: ?[*]const u8,
    data_len: usize,
    out: *SysImage,
) callconv(.c) bool {
    _ = userdata;

    const alloc = allocator orelse return false;
    const bytes: []const u8 = if (data) |ptr|
        ptr[0..data_len]
    else
        // A null pointer with a non-zero length is malformed input.
        if (data_len > 0) return false else &.{};

    return decodePng(bytes, alloc.*, out);
}

/// Rejects headers libspng would reject anyway, but before it allocates
/// per-image state. Keeps the well-formed PNG field ranges explicit (RFC 2083
/// §11.2.2): bit depths 1/2/4/8/16, color types 0/2/3/4/6, deflate
/// compression, adaptive filtering, no interlace or Adam7.
fn headerIsValid(ihdr: *const SpngIhdr) bool {
    const depth_ok = switch (ihdr.bit_depth) {
        1, 2, 4, 8, 16 => true,
        else => false,
    };
    const color_ok = switch (ihdr.color_type) {
        0, 2, 3, 4, 6 => true,
        else => false,
    };
    return depth_ok and
        color_ok and
        ihdr.compression_method == 0 and
        ihdr.filter_method == 0 and
        ihdr.interlace_method <= 1;
}