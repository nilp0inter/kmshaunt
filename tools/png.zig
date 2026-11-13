//! Deterministic PNG encoder for the T2 headless-render goldens (ROADMAP §4 T2,
//! R6: a toolchain bump that changes pixels must show up as a byte diff).
//!
//! # Output shape
//!
//! A file is the 8-byte signature followed by exactly three chunks, in order,
//! and nothing else:
//!
//! | chunk  | payload |
//! |--------|---------|
//! | `IHDR` | width, height, bit depth 8, color type 0/2/6, compression 0, filter method 0, interlace 0 |
//! | `IDAT` | one zlib stream holding every filtered scanline |
//! | `IEND` | empty |
//!
//! No ancillary chunk is ever written (`PLTE`, `tRNS`, `gAMA`, `sRGB`, `tIME`,
//! `tEXt`, `pHYs`, …). Every one of them would add bytes that do not depend on
//! the pixels, and several of them carry machine state (timestamps, gamma of the
//! host) that would break reproducibility.
//!
//! # Determinism
//!
//! The output is a pure function of the `Image`, with no timestamps, no
//! randomness, no locale and no allocator-address dependence:
//!
//! * Each scanline is prefixed with filter type 0 (None), so the raw stream is
//!   exactly `height * (1 + width * bytes_per_pixel)` bytes with no adaptive
//!   per-row filtering. Rows go out in top-to-bottom, left-to-right order.
//! * That stream is deflated by `std.compress.flate.Compress` with the pinned
//!   `Options.level_9` preset (`good = 32`, `nice = 258`, `lazy = 258`,
//!   `chain = 4096`), fed as one logical stream in a single fixed order.
//! * The zlib envelope (RFC 1950) is written here rather than by the flate
//!   container so the header bits are pinned: `78 DA`, i.e. CM = 8 (deflate),
//!   CINFO = 7 (32 KiB window), FLEVEL = 3 (maximum compression), FDICT = 0,
//!   FCHECK = 26, then a big-endian Adler-32 of the filtered stream. This is the
//!   same envelope `zlib.compress(data, 9)` produces, which lets goldens be
//!   cross-checked against an independent encoder; for the 1x1 case the deflate
//!   payload is byte-identical too (see the golden test at the bottom).
//! * Chunk lengths are big-endian `u32`; each chunk's CRC-32 is the standard
//!   CRC-32/ISO-HDLC over type and payload (`std.hash.Crc32`).
//!
//! A std upgrade that changes deflate output changes these bytes. That is the
//! point: the golden test pins one known-good file, so a lock bump shows a
//! reviewable diff instead of silent pixel drift.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const flate = std.compress.flate;

/// PNG file signature (PNG spec, §5.2).
pub const signature = "\x89PNG\r\n\x1a\n";

/// Largest width or height a PNG can express (2^31 - 1, PNG spec §11.2.2).
pub const max_dimension: u32 = std.math.maxInt(i31);

/// The pixel formats this encoder writes. Channel order is PNG's: `rgb24` is
/// R,G,B and `rgba32` is R,G,B,A, 8 bits per channel, no premultiplication.
pub const Format = enum { gray8, rgb24, rgba32 };

pub const Image = struct {
    /// Pixel width, 1 to `max_dimension`.
    width: u32,
    /// Pixel height, 1 to `max_dimension`.
    height: u32,
    format: Format,
    /// Tightly packed, row-major, no padding, top row first. Exactly
    /// `width * height * bytesPerPixel(format)` bytes, with no row stride.
    pixels: []const u8,
};

/// Bytes per pixel for `format`.
pub fn bytesPerPixel(format: Format) usize {
    return switch (format) {
        .gray8 => 1,
        .rgb24 => 3,
        .rgba32 => 4,
    };
}

/// PNG color type for `format`: 0 grayscale, 2 truecolor, 6 truecolor + alpha.
pub fn colorType(format: Format) u8 {
    return switch (format) {
        .gray8 => 0,
        .rgb24 => 2,
        .rgba32 => 6,
    };
}

/// Errors raised by this module. Image-validation errors are
/// `EmptyImage`, `ImageTooLarge` and `PixelBufferSizeMismatch`; the rest come
/// from the allocator and from the destination writer.
pub const EncodeError = error{
    /// `width` or `height` is zero; PNG requires at least one pixel.
    EmptyImage,
    /// A dimension exceeds `max_dimension`, a length computation overflows, or
    /// the compressed payload does not fit a chunk's 32-bit length field.
    ImageTooLarge,
    /// `pixels.len` is not `width * height * bytesPerPixel(format)`.
    PixelBufferSizeMismatch,
} || Allocator.Error || Writer.Error;

/// Writes `image` to `out` as a PNG file, allocating the compressed payload from
/// `allocator`. Nothing else is allocated and no state is kept between calls, so
/// the same `image` always produces the same bytes.
///
/// `out` must be able to buffer at least 4 bytes (`Writer.writeInt` writes four
/// big-endian bytes per field); `Writer.fixed` and `Writer.Allocating` both
/// qualify, and `error.WriteFailed` is returned if a fixed buffer runs out.
pub fn writePng(allocator: Allocator, out: *Writer, image: Image) EncodeError!void {
    const layout = try checkedLayout(image);

    const idat = try deflateFiltered(allocator, image, layout);
    defer allocator.free(idat);
    if (idat.len > std.math.maxInt(u32)) return error.ImageTooLarge;

    try out.writeAll(signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], image.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], image.height, .big);
    ihdr[8] = 8; // bit depth: 8 bits per sample
    ihdr[9] = colorType(image.format);
    ihdr[10] = 0; // compression method: deflate with a 32 KiB window
    ihdr[11] = 0; // filter method: adaptive filtering (only filter 0 is emitted)
    ihdr[12] = 0; // interlace method: none (no Adam7)

    try writeChunk(out, "IHDR", &ihdr);
    try writeChunk(out, "IDAT", idat);
    try writeChunk(out, "IEND", &.{});
}

/// Encodes `image` to a newly allocated PNG file owned by the caller. Free it
/// with the same `allocator`.
pub fn encodePng(allocator: Allocator, image: Image) EncodeError![]u8 {
    var out: Writer.Allocating = try .initCapacity(allocator, 1024);
    errdefer out.deinit();
    try writePng(allocator, &out.writer, image);
    return out.toOwnedSlice();
}

/// PNG chunk framing: big-endian length, type, payload, big-endian CRC-32 over
/// type + payload.
fn writeChunk(out: *Writer, kind: *const [4]u8, data: []const u8) Writer.Error!void {
    std.debug.assert(data.len <= std.math.maxInt(u32));
    try out.writeInt(u32, @intCast(data.len), .big);
    try out.writeAll(kind);
    try out.writeAll(data);

    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try out.writeInt(u32, crc.final(), .big);
}

/// zlib header (RFC 1950 §2.2): CM 8, CINFO 7 (32 KiB window), FLEVEL 3
/// (maximum compression), FDICT 0, FCHECK 26 — what `zlib.compress(x, 9)`
/// emits. Paired with a raw deflate body and an Adler-32 trailer below.
const zlib_header = [2]u8{ 0x78, 0xda };

/// Filter type 0 (None), the only filter this encoder emits. PNG spec §9.2.
const filter_none = [1]u8{0x00};

/// Compression preset, pinned for byte-stable output. `level_9` is zlib's
/// `deflateInit(..., 9)` parameter set as mirrored by Zig's flate encoder.
const compress_options: flate.Compress.Options = .level_9;

const Layout = struct {
    row_bytes: usize,
    /// Filtered scanline stream: `height` filter bytes plus all pixels.
    raw_len: usize,
};

fn checkedLayout(image: Image) EncodeError!Layout {
    if (image.width == 0 or image.height == 0) return error.EmptyImage;
    if (image.width > max_dimension or image.height > max_dimension) return error.ImageTooLarge;

    const bpp = bytesPerPixel(image.format);
    const row_bytes = std.math.mul(usize, image.width, bpp) catch return error.ImageTooLarge;
    const pixel_len = std.math.mul(usize, row_bytes, image.height) catch return error.ImageTooLarge;
    const raw_len = std.math.add(usize, pixel_len, image.height) catch return error.ImageTooLarge;
    if (image.pixels.len != pixel_len) return error.PixelBufferSizeMismatch;

    return .{ .row_bytes = row_bytes, .raw_len = raw_len };
}

/// Deflates the filtered scanline stream into a complete zlib stream
/// (header, deflate body, Adler-32), allocated from `allocator`.
fn deflateFiltered(allocator: Allocator, image: Image, layout: Layout) EncodeError![]u8 {
    // Deflate's worst case is a few bytes over the input (stored blocks cost 5
    // bytes per 65535-byte block). Start there and let the growing
    // `Writer.Allocating` take over if the encoder ever does worse.
    const initial_capacity = layout.raw_len +| layout.raw_len / 16 +| 64;

    var out: Writer.Allocating = try .initCapacity(allocator, initial_capacity);
    errdefer out.deinit();
    try out.writer.writeAll(&zlib_header);

    const history = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(history);

    var compressor = try flate.Compress.init(&out.writer, history, .raw, compress_options);

    // The `.raw` container computes no checksum, so the Adler-32 of the filtered
    // stream is tracked here and appended as the zlib trailer.
    var adler: std.hash.Adler32 = .{};
    var y: usize = 0;
    while (y < @as(usize, image.height)) : (y += 1) {
        const row = image.pixels[y * layout.row_bytes ..][0..layout.row_bytes];
        try compressor.writer.writeAll(&filter_none);
        try compressor.writer.writeAll(row);
        adler.update(&filter_none);
        adler.update(row);
    }
    try compressor.finish();

    try out.writer.writeInt(u32, adler.adler, .big);
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Chunk = struct {
    kind: [4]u8,
    data: []const u8,
};

const ChunkList = struct {
    chunks: [8]Chunk,
    len: usize,
};

fn readU32(bytes: []const u8) u32 {
    var buf: [4]u8 = undefined;
    @memcpy(&buf, bytes[0..4]);
    return std.mem.readInt(u32, &buf, .big);
}

/// Walks a PNG, verifying the signature, every chunk length, every CRC-32, and
/// that the chunks tile the file exactly (no trailing bytes).
fn parsePng(bytes: []const u8) !ChunkList {
    try testing.expect(bytes.len >= signature.len + 12);
    try testing.expectEqualStrings(signature, bytes[0..signature.len]);

    var list: ChunkList = .{ .chunks = undefined, .len = 0 };
    var i: usize = signature.len;
    while (i < bytes.len) {
        try testing.expect(i + 12 <= bytes.len);
        const len = readU32(bytes[i..][0..4]);
        try testing.expect(len <= bytes.len - i - 12);

        var kind: [4]u8 = undefined;
        @memcpy(&kind, bytes[i + 4 ..][0..4]);
        const data = bytes[i + 8 ..][0..len];
        const stored_crc = readU32(bytes[i + 8 + len ..][0..4]);

        var crc: std.hash.Crc32 = .init();
        crc.update(&kind);
        crc.update(data);
        try testing.expectEqual(crc.final(), stored_crc);

        try testing.expect(list.len < list.chunks.len);
        list.chunks[list.len] = .{ .kind = kind, .data = data };
        list.len += 1;

        i += 12 + len;
    }
    try testing.expectEqual(bytes.len, i);
    return list;
}

/// Inflates a zlib stream with Zig's inflater. The zlib container verifies the
/// Adler-32 trailer, so a corrupt or truncated IDAT fails here.
fn inflateZlib(allocator: Allocator, zlib: []const u8) ![]u8 {
    var reader: std.Io.Reader = .fixed(zlib);
    var window: [flate.max_window_len]u8 = undefined;
    var inflater: flate.Decompress = .init(&reader, .zlib, &window);
    return inflater.reader.allocRemaining(allocator, .unlimited);
}

/// Encodes `image`, then checks the chunk list, the IHDR fields and the
/// unfiltered scanline stream against the pixels that went in.
fn expectRoundTrip(allocator: Allocator, image: Image) !void {
    const png = try encodePng(allocator, image);
    defer allocator.free(png);

    const chunks = try parsePng(png);
    try testing.expectEqual(@as(usize, 3), chunks.len);
    try testing.expectEqualStrings("IHDR", &chunks.chunks[0].kind);
    try testing.expectEqualStrings("IDAT", &chunks.chunks[1].kind);
    try testing.expectEqualStrings("IEND", &chunks.chunks[2].kind);
    try testing.expectEqual(@as(usize, 0), chunks.chunks[2].data.len);

    const ihdr = chunks.chunks[0].data;
    try testing.expectEqual(@as(usize, 13), ihdr.len);
    try testing.expectEqual(image.width, readU32(ihdr[0..4]));
    try testing.expectEqual(image.height, readU32(ihdr[4..8]));
    try testing.expectEqual(@as(u8, 8), ihdr[8]); // bit depth
    try testing.expectEqual(colorType(image.format), ihdr[9]);
    try testing.expectEqual(@as(u8, 0), ihdr[10]); // compression
    try testing.expectEqual(@as(u8, 0), ihdr[11]); // filter method
    try testing.expectEqual(@as(u8, 0), ihdr[12]); // interlace

    const filtered = try inflateZlib(allocator, chunks.chunks[1].data);
    defer allocator.free(filtered);

    const row_bytes = @as(usize, image.width) * bytesPerPixel(image.format);
    try testing.expectEqual((row_bytes + 1) * @as(usize, image.height), filtered.len);
    for (0..@as(usize, image.height)) |y| {
        const start = y * (row_bytes + 1);
        try testing.expectEqual(@as(u8, 0), filtered[start]);
        try testing.expectEqualSlices(
            u8,
            image.pixels[y * row_bytes ..][0..row_bytes],
            filtered[start + 1 ..][0..row_bytes],
        );
    }
}

test "2x2 RGBA: signature, chunk walk with CRCs, inflate back to filtered scanlines" {
    const allocator = testing.allocator;
    const pixels = [_]u8{
        0xff, 0x00, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, // red, green
        0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // blue, white
    };
    const image: Image = .{ .width = 2, .height = 2, .format = .rgba32, .pixels = &pixels };

    const png = try encodePng(allocator, image);
    defer allocator.free(png);

    const chunks = try parsePng(png);
    try testing.expectEqual(@as(usize, 3), chunks.len);
    try testing.expectEqualStrings("IHDR", &chunks.chunks[0].kind);
    try testing.expectEqualStrings("IDAT", &chunks.chunks[1].kind);
    try testing.expectEqualStrings("IEND", &chunks.chunks[2].kind);
    try testing.expectEqual(@as(usize, 0), chunks.chunks[2].data.len);

    // IHDR: width, height, bit depth 8, truecolor + alpha, no compression/filter/interlace.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2, 0, 0, 0, 2, 8, 6, 0, 0, 0 }, chunks.chunks[0].data);

    // IDAT is a zlib stream and starts with the pinned header.
    try testing.expect(chunks.chunks[1].data.len >= 6);
    try testing.expectEqualSlices(u8, &zlib_header, chunks.chunks[1].data[0..2]);

    const filtered = try inflateZlib(allocator, chunks.chunks[1].data);
    defer allocator.free(filtered);

    const expected_filtered = [_]u8{
        0x00, 0xff, 0x00, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, // filter 0 + row 0
        0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // filter 0 + row 1
    };
    try testing.expectEqualSlices(u8, &expected_filtered, filtered);
}

test "IHDR fields and scanline layout for all three formats" {
    const allocator = testing.allocator;

    // 3x2 grayscale.
    const gray = [_]u8{ 0x00, 0x40, 0x80, 0xc0, 0xff, 0x7f };
    try expectRoundTrip(allocator, .{ .width = 3, .height = 2, .format = .gray8, .pixels = &gray });

    // 2x3 truecolor.
    const rgb = blk: {
        var bytes: [2 * 3 * 3]u8 = undefined;
        for (&bytes, 0..) |*b, i| b.* = @intCast((i * 37 + 11) % 256);
        break :blk bytes;
    };
    try expectRoundTrip(allocator, .{ .width = 2, .height = 3, .format = .rgb24, .pixels = &rgb });

    // 3x2 truecolor + alpha.
    const rgba = blk: {
        var bytes: [3 * 2 * 4]u8 = undefined;
        for (&bytes, 0..) |*b, i| b.* = @intCast((i * 53 + 7) % 256);
        break :blk bytes;
    };
    try expectRoundTrip(allocator, .{ .width = 3, .height = 2, .format = .rgba32, .pixels = &rgba });
}

test "identical input encodes to identical bytes" {
    const allocator = testing.allocator;
    const pixels = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
    };
    const image: Image = .{ .width = 2, .height = 2, .format = .rgba32, .pixels = &pixels };

    const first = try encodePng(allocator, image);
    defer allocator.free(first);
    const second = try encodePng(allocator, image);
    defer allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);

    // The destination writer must not influence the bytes either.
    var buffer: [512]u8 = undefined;
    var fixed_writer: Writer = .fixed(&buffer);
    try writePng(allocator, &fixed_writer, image);
    try testing.expectEqualSlices(u8, first, fixed_writer.buffered());
}

test "CRC-32 matches the standard check value" {
    try testing.expectEqual(@as(u32, 0xCBF43926), std.hash.Crc32.hash("123456789"));
}

test "1x1 gray PNG matches the Python zlib reference byte for byte" {
    // Reference produced with an independent implementation:
    //
    //   nix run nixpkgs#python3 -- -c '
    //   import zlib, struct, binascii
    //   def chunk(t, d):
    //       return struct.pack(">I", len(d)) + t + d + struct.pack(">I", binascii.crc32(t + d) & 0xffffffff)
    //   png = (b"\x89PNG\r\n\x1a\n"
    //          + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0))
    //          + chunk(b"IDAT", zlib.compress(b"\x00\x80", 9))
    //          + chunk(b"IEND", b""))
    //   print(",".join("0x%02x" % b for b in png))'
    //
    // 67 bytes: signature, IHDR (13-byte payload), IDAT (10-byte zlib stream),
    // IEND. The deflate body Zig emits for this input is identical to zlib's.
    const expected = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // signature
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, // IHDR, length 13
        0x00, 0x00, 0x00, 0x01, // width 1
        0x00, 0x00, 0x00, 0x01, // height 1
        0x08, 0x00, 0x00, 0x00, 0x00, // depth 8, gray, deflate, filter 0, no interlace
        0x3a, 0x7e, 0x9b, 0x55, // IHDR CRC-32
        0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, 0x54, // IDAT, length 10
        0x78, 0xda, // zlib header: deflate, 32 KiB window, FLEVEL 3
        0x63, 0x68, 0x00, 0x00, 0x00, 0x82, 0x00, 0x81, // deflate body + Adler-32
        0xda, 0x45, 0x08, 0x3b, // IDAT CRC-32
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, // IEND, length 0
        0xae, 0x42, 0x60, 0x82, // IEND CRC-32
    };

    const allocator = testing.allocator;
    const pixel = [1]u8{0x80};
    const png = try encodePng(allocator, .{ .width = 1, .height = 1, .format = .gray8, .pixels = &pixel });
    defer allocator.free(png);

    try testing.expectEqual(@as(usize, expected.len), png.len);
    try testing.expectEqualSlices(u8, &expected, png);

    // …and the pinned file still inflates to the expected filtered scanline.
    const chunks = try parsePng(png);
    try testing.expectEqual(@as(usize, 3), chunks.len);
    const filtered = try inflateZlib(allocator, chunks.chunks[1].data);
    defer allocator.free(filtered);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x80 }, filtered);
}

test "rejects images that cannot be encoded" {
    const allocator = testing.allocator;
    const pixels = [_]u8{ 0, 0, 0 };
    try testing.expectError(
        error.PixelBufferSizeMismatch,
        encodePng(allocator, .{ .width = 2, .height = 2, .format = .gray8, .pixels = &pixels }),
    );
    try testing.expectError(
        error.EmptyImage,
        encodePng(allocator, .{ .width = 0, .height = 2, .format = .gray8, .pixels = &.{} }),
    );
    try testing.expectError(
        error.ImageTooLarge,
        encodePng(allocator, .{ .width = max_dimension + 1, .height = 1, .format = .rgba32, .pixels = &.{} }),
    );
}