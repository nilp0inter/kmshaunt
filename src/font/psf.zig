//! src/font/psf.zig -- PSF1/PSF2 console font decoder (ROADMAP M3.9).
//!
//! `font-engine=psf` loads the console font named by `font-name` (Terminus and
//! friends ship as `.psf`/`.psfu` files). This module is only the container
//! parser and rasterizer; discovery and the engine plumbing live above it.
//! Parsing is allocation-bounded: the glyph bitmaps are copied once into an
//! owned buffer and the Unicode table is folded into one hash map keyed by the
//! UTF-8 encoding of the mapped codepoint sequence.
//!
//! Both container versions are accepted transparently, including the common
//! case of a gzip-compressed file (`0x1f 0x8b`, as in `/usr/share/consolefonts`
//! and the kbd `*.psfu.gz` files):
//!
//!   * PSF1: magic `0x36 0x04`, mode byte, charsize byte. Glyphs are 8 pixels
//!     wide and `charsize` rows tall (one byte per row). Mode bit 0 selects
//!     512 glyphs instead of 256, bit 1 declares a Unicode table of
//!     little-endian `u16` values after the glyph data. `0xFFFF` terminates the
//!     value list of one glyph (moving on to the next glyph); `0xFFFE` starts a
//!     multi-codepoint sequence whose values run until that glyph's `0xFFFF`.
//!   * PSF2: magic `0x72 0xb5 0x4a 0x86`, version, headersize, flags, glyph
//!     count, charsize, height, width. Rows are `ceil(width / 8)` bytes wide,
//!     MSB leftmost; `charsize` is the stride per glyph and may exceed
//!     `height * ceil(width / 8)` (trailing padding is ignored). Flag bit 0
//!     declares a UTF-8 encoded Unicode table *after* the glyph data: `0xFF`
//!     terminates the value list of one glyph, `0xFE` starts a multi-codepoint
//!     sequence that runs to the terminating `0xFF` of that same glyph entry.
//!
//! Lookup policy (`lookupSequence`): a sequence is matched longest-first. A
//! font that maps both `fi` and `fio` to (different) glyphs resolves the input
//! `fio` to the three-codepoint glyph and `fix` to the two-codepoint glyph,
//! because the renderer passes the whole grapheme cluster and the longest
//! prefix wins. `lookupCodepoint` only answers for single-codepoint mappings;
//! a glyph mapped exclusively through a multi-codepoint sequence is not
//! returned by it. When a font lists the same sequence twice, the later entry
//! wins: the table is folded in file order and the last value for a key is
//! stored.
//!
//! Rasterization (`renderGlyph`) expands one glyph into `width * height`
//! coverage bytes, row-major, `255` for a set bit and `0` for a clear bit. The
//! caller supplies the buffer; only fully in-range glyph indices are accepted.

const std = @import("std");

const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Longest multi-codepoint sequence accepted from a Unicode table, in
/// codepoints. Real console fonts use two or three; the bound only sizes the
/// lookup scratch buffer, so anything this long would be pathological.
pub const max_sequence_codepoints: usize = 255;

/// PSF1 magic bytes (`PSF1_MAGIC0`, `PSF1_MAGIC1`).
const psf1_magic = [2]u8{ 0x36, 0x04 };

/// PSF2 magic bytes, in file order (`PSF2_MAGIC` is 0x864ab572 little-endian).
const psf2_magic = [4]u8{ 0x72, 0xb5, 0x4a, 0x86 };

/// Gzip magic bytes, which the Linux console tooling happily accepts in front
/// of an otherwise ordinary PSF file.
const gzip_magic = [2]u8{ 0x1f, 0x8b };

/// Everything that can go wrong while decoding a font.
pub const PsfError = Allocator.Error || error{
    /// Neither PSF1 nor PSF2 (and not gzip-wrapped PSF).
    InvalidMagic,
    /// A fixed header does not fit in the input.
    TruncatedHeader,
    /// The glyph data announced by the header does not fit in the input.
    TruncatedGlyphData,
    /// Zero-sized or otherwise unusable glyph cells.
    InvalidGlyphSize,
    /// A PSF2 header announces an empty font.
    NoGlyphs,
    /// The Unicode table ends in the middle of a value.
    TruncatedUnicodeTable,
    /// A Unicode table value is malformed (bad UTF-8, bad sequence length).
    InvalidUnicodeTable,
    /// A codepoint cannot be encoded as UTF-8 (surrogate halves).
    InvalidCodepoint,
    /// The gzip container is truncated or fails its checksum.
    CorruptCompression,
    /// `renderGlyph` was given an index past `glyph_count`.
    InvalidGlyphIndex,
    /// `renderGlyph`'s output buffer is smaller than `width * height`.
    BufferTooSmall,
};

/// A parsed console font. The glyph bitmaps and the mapping keys are owned by
/// the font; the input buffer may be freed after `parse` returns.
pub const PsfFont = struct {
    allocator: Allocator,
    /// Glyph cell width in pixels (always 8 for PSF1).
    width: u16,
    /// Glyph cell height in pixels.
    height: u16,
    /// Number of glyphs in the font.
    glyph_count: u32,
    /// Bytes per glyph as stored in the file (`>= height * ceil(width / 8)`).
    charsize: usize,
    /// Owned copy of the glyph bitmap block, `glyph_count * charsize` bytes.
    glyphs: []u8,
    /// Codepoint sequence (UTF-8) -> glyph index. Keys are owned slices.
    mappings: std.StringHashMapUnmanaged(u32) = .empty,
    /// Longest sequence in `mappings`, in codepoints (0 when the font has no
    /// Unicode table).
    max_sequence_len: u8 = 0,

    /// Parse a PSF1 or PSF2 font, transparently inflating a gzip container.
    /// The returned font owns its data; `deinit` releases it.
    pub fn parse(allocator: Allocator, bytes: []const u8) PsfError!PsfFont {
        if (bytes.len >= gzip_magic.len and
            bytes[0] == gzip_magic[0] and bytes[1] == gzip_magic[1])
        {
            const inflated = try inflateGzip(allocator, bytes);
            defer allocator.free(inflated);
            return parseUncompressed(allocator, inflated);
        }
        return parseUncompressed(allocator, bytes);
    }

    /// Release the glyph block and every owned mapping key.
    pub fn deinit(self: *PsfFont) void {
        var it = self.mappings.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.mappings.deinit(self.allocator);
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }

    /// Width in pixels of one glyph cell.
    pub fn cellWidth(self: *const PsfFont) u16 {
        return self.width;
    }

    /// Height in pixels of one glyph cell.
    pub fn cellHeight(self: *const PsfFont) u16 {
        return self.height;
    }

    /// Resolve a single codepoint through the Unicode table. Returns null for
    /// unmapped codepoints and for codepoints that are only part of a
    /// multi-codepoint sequence (see `lookupSequence`).
    pub fn lookupCodepoint(self: *const PsfFont, cp: u21) ?u32 {
        var key: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &key) catch return null;
        return self.mappings.get(key[0..len]);
    }

    /// Resolve a codepoint sequence, longest prefix first. `codepoints` is the
    /// full grapheme cluster (or any lookahead) supplied by the caller; the
    /// longest prefix present in the table wins. Returns null when no prefix
    /// is mapped.
    pub fn lookupSequence(self: *const PsfFont, codepoints: []const u21) ?u32 {
        if (codepoints.len == 0 or self.max_sequence_len == 0) return null;

        var key: [max_sequence_codepoints * 4]u8 = undefined;
        // `prefix_len[i]` is the byte length of the UTF-8 encoding of
        // `codepoints[0 .. i + 1]`.
        var prefix_len: [max_sequence_codepoints]usize = undefined;
        var count: usize = 0;
        var byte_len: usize = 0;
        while (count < codepoints.len and count < max_sequence_codepoints) : (count += 1) {
            if (byte_len + 4 > key.len) break;
            const len = std.unicode.utf8Encode(codepoints[count], key[byte_len..]) catch return null;
            byte_len += len;
            prefix_len[count] = byte_len;
        }

        var len = @min(count, @as(usize, self.max_sequence_len));
        while (len > 0) : (len -= 1) {
            if (self.mappings.get(key[0..prefix_len[len - 1]])) |glyph| return glyph;
        }
        return null;
    }

    /// Rasterize one glyph into `out_alpha` (row-major, `width * height`
    /// bytes; `255` where the 1-bit source is set, `0` otherwise).
    pub fn renderGlyph(self: *const PsfFont, glyph_index: u32, out_alpha: []u8) PsfError!void {
        if (glyph_index >= self.glyph_count) return error.InvalidGlyphIndex;
        const width: usize = self.width;
        const height: usize = self.height;
        const stride = (width + 7) / 8;
        if (out_alpha.len < width * height) return error.BufferTooSmall;

        const start = @as(usize, glyph_index) * self.charsize;
        const src = self.glyphs[start..][0..self.charsize];
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const byte = src[y * stride + x / 8];
                const shift: u3 = @intCast(7 - (x % 8));
                out_alpha[y * width + x] = if ((byte >> shift) & 1 != 0) 255 else 0;
            }
        }
    }

    /// Fold one (possibly empty) glyph entry into the map. `sequence` is the
    /// codepoint list for the entry; empty means "no mapping".
    fn addSequence(self: *PsfFont, sequence: []const u21, glyph: u32) PsfError!void {
        if (sequence.len == 0) return;
        if (sequence.len > max_sequence_codepoints) return error.InvalidUnicodeTable;

        var key: [max_sequence_codepoints * 4]u8 = undefined;
        var byte_len: usize = 0;
        for (sequence) |cp| {
            const len = std.unicode.utf8Encode(cp, key[byte_len..]) catch return error.InvalidCodepoint;
            byte_len += len;
        }
        try self.insertMapping(key[0..byte_len], glyph);

        const seq_len: u8 = @intCast(sequence.len);
        if (seq_len > self.max_sequence_len) self.max_sequence_len = seq_len;
    }

    fn addCodepoint(self: *PsfFont, cp: u21, glyph: u32) PsfError!void {
        var key: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &key) catch return error.InvalidCodepoint;
        try self.insertMapping(key[0..len], glyph);
        if (self.max_sequence_len == 0) self.max_sequence_len = 1;
    }

    fn insertMapping(self: *PsfFont, key: []const u8, glyph: u32) PsfError!void {
        if (self.mappings.getPtr(key)) |slot| {
            slot.* = glyph;
            return;
        }
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        try self.mappings.put(self.allocator, owned, glyph);
    }

    /// PSF1 Unicode table: positional little-endian `u16` values per glyph.
    fn parsePsf1UnicodeTable(self: *PsfFont, table: []const u8) PsfError!void {
        var sequence: [max_sequence_codepoints]u21 = undefined;
        var sequence_len: usize = 0;
        var in_sequence = false;
        var glyph: u32 = 0;
        var pos: usize = 0;

        while (glyph < self.glyph_count and pos + 2 <= table.len) {
            const value = std.mem.readInt(u16, table[pos..][0..2], .little);
            pos += 2;

            switch (value) {
                0xFFFF => {
                    if (in_sequence) {
                        try self.addSequence(sequence[0..sequence_len], glyph);
                        in_sequence = false;
                        sequence_len = 0;
                    }
                    glyph += 1;
                },
                0xFFFE => {
                    in_sequence = true;
                    sequence_len = 0;
                },
                else => {
                    const cp: u21 = @intCast(value);
                    if (in_sequence) {
                        if (sequence_len == sequence.len) return error.InvalidUnicodeTable;
                        sequence[sequence_len] = cp;
                        sequence_len += 1;
                    } else {
                        try self.addCodepoint(cp, glyph);
                    }
                },
            }
        }

        // Tolerate a table whose final 0xFFFF is missing.
        if (in_sequence and sequence_len > 0 and glyph < self.glyph_count) {
            try self.addSequence(sequence[0..sequence_len], glyph);
        }
    }

    /// PSF2 Unicode table: positional UTF-8 values per glyph.
    fn parsePsf2UnicodeTable(self: *PsfFont, table: []const u8) PsfError!void {
        var sequence: [max_sequence_codepoints]u21 = undefined;
        var sequence_len: usize = 0;
        var in_sequence = false;
        var glyph: u32 = 0;
        var pos: usize = 0;

        while (glyph < self.glyph_count and pos < table.len) {
            const byte = table[pos];
            switch (byte) {
                0xFF => {
                    pos += 1;
                    if (in_sequence) {
                        try self.addSequence(sequence[0..sequence_len], glyph);
                        in_sequence = false;
                        sequence_len = 0;
                    }
                    glyph += 1;
                },
                0xFE => {
                    pos += 1;
                    in_sequence = true;
                    sequence_len = 0;
                },
                else => {
                    const len = std.unicode.utf8ByteSequenceLength(byte) catch
                        return error.InvalidUnicodeTable;
                    if (pos + len > table.len) return error.TruncatedUnicodeTable;
                    const cp = std.unicode.utf8Decode(table[pos..][0..len]) catch
                        return error.InvalidUnicodeTable;
                    pos += len;
                    if (in_sequence) {
                        if (sequence_len == sequence.len) return error.InvalidUnicodeTable;
                        sequence[sequence_len] = @intCast(cp);
                        sequence_len += 1;
                    } else {
                        try self.addCodepoint(@intCast(cp), glyph);
                    }
                },
            }
        }

        // Tolerate a table whose final 0xFF is missing.
        if (in_sequence and sequence_len > 0 and glyph < self.glyph_count) {
            try self.addSequence(sequence[0..sequence_len], glyph);
        }
    }
};

fn parseUncompressed(allocator: Allocator, bytes: []const u8) PsfError!PsfFont {
    if (bytes.len < psf1_magic.len) return error.TruncatedHeader;
    if (bytes[0] == psf1_magic[0] and bytes[1] == psf1_magic[1]) {
        return parsePsf1(allocator, bytes);
    }
    if (bytes.len >= psf2_magic.len and
        bytes[0] == psf2_magic[0] and bytes[1] == psf2_magic[1] and
        bytes[2] == psf2_magic[2] and bytes[3] == psf2_magic[3])
    {
        return parsePsf2(allocator, bytes);
    }
    return error.InvalidMagic;
}

fn parsePsf1(allocator: Allocator, bytes: []const u8) PsfError!PsfFont {
    if (bytes.len < 4) return error.TruncatedHeader;
    const mode = bytes[2];
    const charsize: u8 = bytes[3];
    if (charsize == 0) return error.InvalidGlyphSize;

    const glyph_count: u32 = if (mode & 0x01 != 0) 512 else 256;
    const data_len = @as(usize, glyph_count) * charsize;
    const data_off: usize = 4;
    if (bytes.len < data_off + data_len) return error.TruncatedGlyphData;

    var font: PsfFont = .{
        .allocator = allocator,
        .width = 8,
        .height = charsize,
        .glyph_count = glyph_count,
        .charsize = charsize,
        .glyphs = try allocator.dupe(u8, bytes[data_off..][0..data_len]),
    };
    errdefer font.deinit();

    if (mode & 0x02 != 0) {
        try font.parsePsf1UnicodeTable(bytes[data_off + data_len ..]);
    }
    return font;
}

fn parsePsf2(allocator: Allocator, bytes: []const u8) PsfError!PsfFont {
    if (bytes.len < 32) return error.TruncatedHeader;

    // Header layout (all little-endian u32 after the magic):
    //   4: version, 8: headersize, 12: flags, 16: length,
    //   20: charsize, 24: height, 28: width.
    const headersize = std.mem.readInt(u32, bytes[8..12], .little);
    const flags = std.mem.readInt(u32, bytes[12..16], .little);
    const glyph_count = std.mem.readInt(u32, bytes[16..20], .little);
    const charsize_u32 = std.mem.readInt(u32, bytes[20..24], .little);
    const height = std.mem.readInt(u32, bytes[24..28], .little);
    const width = std.mem.readInt(u32, bytes[28..32], .little);

    if (glyph_count == 0) return error.NoGlyphs;
    if (width == 0 or height == 0) return error.InvalidGlyphSize;
    if (width > 256 or height > 256) return error.InvalidGlyphSize;
    if (headersize < 32) return error.InvalidGlyphSize;
    if (headersize > bytes.len) return error.TruncatedHeader;

    const stride = (@as(usize, width) + 7) / 8;
    const min_charsize = stride * height;
    if (charsize_u32 < min_charsize) return error.InvalidGlyphSize;

    const charsize: usize = charsize_u32;
    const data_len = std.math.mul(usize, glyph_count, charsize) catch
        return error.InvalidGlyphSize;
    const data_off: usize = headersize;
    if (data_len > bytes.len - data_off) return error.TruncatedGlyphData;

    var font: PsfFont = .{
        .allocator = allocator,
        .width = @intCast(width),
        .height = @intCast(height),
        .glyph_count = glyph_count,
        .charsize = charsize,
        .glyphs = try allocator.dupe(u8, bytes[data_off..][0..data_len]),
    };
    errdefer font.deinit();

    if (flags & 0x01 != 0) {
        try font.parsePsf2UnicodeTable(bytes[data_off + data_len ..]);
    }
    return font;
}

/// Inflate a gzip-wrapped font into a new allocation. The deflate errors are
/// collapsed into `CorruptCompression` (the detailed reason lives in the
/// decompressor's `err` field, which the public API does not expose); a
/// `WriteFailed` from the in-memory allocating writer can only be OOM.
fn inflateGzip(allocator: Allocator, bytes: []const u8) PsfError![]u8 {
    var input: std.Io.Reader = .fixed(bytes);
    var decompress = flate.Decompress.init(&input, .gzip, &.{});

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    _ = decompress.reader.streamRemaining(&out.writer) catch |err| switch (err) {
        error.ReadFailed => return error.CorruptCompression,
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests. Synthetic fonts are built byte by byte so every field of both
// containers is exercised without shipping binary fixtures.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn appendU16Le(list: *std.ArrayList(u8), allocator: Allocator, value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try list.appendSlice(allocator, &bytes);
}

/// Append one PSF1 Unicode-table entry: the codepoints, then `0xFFFF`.
fn appendPsf1Entry(list: *std.ArrayList(u8), allocator: Allocator, entry: []const u16) !void {
    for (entry) |value| try appendU16Le(list, allocator, value);
    try appendU16Le(list, allocator, 0xFFFF);
}

/// Build a 256-glyph PSF1 font with a Unicode table covering glyphs
/// `0x00..0x44`. The glyph block deliberately carries recognisable patterns at
/// `0x41` (stripes) and `0x42` (all lit).
fn buildPsf1(allocator: Allocator, glyph_count: u32) ![]u8 {
    const charsize: u8 = 16;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    const mode: u8 = 0x02 | if (glyph_count == 512) @as(u8, 0x01) else 0;
    try list.appendSlice(allocator, &.{ psf1_magic[0], psf1_magic[1], mode, charsize });

    var index: u32 = 0;
    while (index < glyph_count) : (index += 1) {
        var glyph: [16]u8 = @splat(0);
        if (index == 0x41) {
            for (0..16) |row| glyph[row] = if (row % 2 == 0) 0x0F else 0xF0;
        } else if (index == 0x42) {
            glyph = @splat(0xFF);
        }
        try list.appendSlice(allocator, &glyph);
    }

    // Positional entries: every slot up to 0x44 must be present, empty slots
    // are a bare 0xFFFF.
    const last_entry: u32 = 0x44;
    index = 0;
    while (index <= last_entry) : (index += 1) {
        switch (index) {
            0x00 => try appendPsf1Entry(&list, allocator, &.{0x0020}),
            0x10 => try appendPsf1Entry(&list, allocator, &.{ 0x00E9, 0x00C9 }),
            0x41 => try appendPsf1Entry(&list, allocator, &.{0x0041}),
            0x42 => try appendPsf1Entry(&list, allocator, &.{0x0042}),
            // A glyph reachable both directly and through the sequence below.
            0x43 => try appendPsf1Entry(&list, allocator, &.{
                0x0066, 0xFFFE, 0x0066, 0x0069,
            }),
            // Only reachable as the longer "fio" sequence.
            0x44 => try appendPsf1Entry(&list, allocator, &.{
                0xFFFE, 0x0066, 0x0069, 0x006F,
            }),
            else => try appendPsf1Entry(&list, allocator, &.{}),
        }
    }

    return list.toOwnedSlice(allocator);
}

/// Build a PSF2 font with `glyph_count` glyphs of `width x height` pixels.
/// Glyph 0 is 'A'-shaped, every other glyph is a repeating 0xAA/0x55 pattern
/// so stride handling is visible in the raster.
fn buildPsf2(
    allocator: Allocator,
    width: u32,
    height: u32,
    glyph_count: u32,
    flags: u32,
    unicode_table: []const u8,
) ![]u8 {
    const charsize = ((width + 7) / 8) * height;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var header: [32]u8 = undefined;
    @memcpy(header[0..4], &psf2_magic);
    std.mem.writeInt(u32, header[4..8], 0, .little); // version
    std.mem.writeInt(u32, header[8..12], 32, .little); // headersize
    std.mem.writeInt(u32, header[12..16], flags, .little);
    std.mem.writeInt(u32, header[16..20], glyph_count, .little);
    std.mem.writeInt(u32, header[20..24], charsize, .little);
    std.mem.writeInt(u32, header[24..28], height, .little);
    std.mem.writeInt(u32, header[28..32], width, .little);
    try list.appendSlice(allocator, &header);

    const stride: usize = (width + 7) / 8;
    var index: u32 = 0;
    while (index < glyph_count) : (index += 1) {
        var glyph: [32]u8 = @splat(0);
        std.debug.assert(charsize <= glyph.len);
        if (index == 0) {
            // Row 0 gets its low byte set: top-left run of the first 8 pixels.
            glyph[0] = 0xFF;
        } else {
            for (0..height) |row| {
                glyph[row * stride] = if (index % 2 == 0) 0xF0 else 0x0F;
            }
        }
        try list.appendSlice(allocator, glyph[0..charsize]);
    }
    try list.appendSlice(allocator, unicode_table);
    return list.toOwnedSlice(allocator);
}

test "psf1: header fields, glyph count and raster" {
    const allocator = testing.allocator;
    const bytes = try buildPsf1(allocator, 256);
    defer allocator.free(bytes);

    var font = try PsfFont.parse(allocator, bytes);
    defer font.deinit();

    try testing.expectEqual(@as(u16, 8), font.cellWidth());
    try testing.expectEqual(@as(u16, 16), font.cellHeight());
    try testing.expectEqual(@as(u32, 256), font.glyph_count);
    try testing.expectEqual(@as(u8, 3), font.max_sequence_len);

    // Raster of glyph 0x41: even rows are 0x0F (right half lit), odd rows are
    // 0xF0 (left half lit). Every output byte is 0 or 255.
    var alpha: [8 * 16]u8 = undefined;
    try font.renderGlyph(0x41, &alpha);
    for (0..16) |row| {
        for (0..8) |col| {
            const expected: u8 = if (row % 2 == 0)
                (if (col >= 4) 255 else 0)
            else
                (if (col < 4) 255 else 0);
            try testing.expectEqual(expected, alpha[row * 8 + col]);
        }
    }

    // Glyph 0x42 is fully lit; the last glyph of the block is empty.
    try font.renderGlyph(0x42, &alpha);
    for (alpha) |value| try testing.expectEqual(@as(u8, 255), value);
    try font.renderGlyph(0xFF, &alpha);
    for (alpha) |value| try testing.expectEqual(@as(u8, 0), value);

    // Out-of-range index and short buffer are reported, not read past.
    try testing.expectError(error.InvalidGlyphIndex, font.renderGlyph(256, &alpha));
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, font.renderGlyph(0, &tiny));
}

test "psf1: Unicode table with multi-codepoint sequences, longest-first" {
    const allocator = testing.allocator;
    const bytes = try buildPsf1(allocator, 256);
    defer allocator.free(bytes);

    var font = try PsfFont.parse(allocator, bytes);
    defer font.deinit();

    try testing.expectEqual(@as(?u32, 0x41), font.lookupCodepoint('A'));
    try testing.expectEqual(@as(?u32, 0x42), font.lookupCodepoint('B'));
    try testing.expectEqual(@as(?u32, 0x00), font.lookupCodepoint(' '));

    // One glyph with two single mappings.
    try testing.expectEqual(@as(?u32, 0x10), font.lookupCodepoint(0x00E9));
    try testing.expectEqual(@as(?u32, 0x10), font.lookupCodepoint(0x00C9));

    // 'f' is mapped directly, and the same glyph also serves the "fi"
    // sequence; "fio" is a different (longer) sequence.
    try testing.expectEqual(@as(?u32, 0x43), font.lookupCodepoint('f'));
    try testing.expectEqual(@as(?u32, 0x43), font.lookupSequence(&.{'f'}));
    try testing.expectEqual(@as(?u32, 0x43), font.lookupSequence(&.{ 'f', 'i' }));
    try testing.expectEqual(@as(?u32, 0x44), font.lookupSequence(&.{ 'f', 'i', 'o' }));
    // Longest-first: unknown tail falls back to the longest known prefix.
    try testing.expectEqual(@as(?u32, 0x43), font.lookupSequence(&.{ 'f', 'i', 'x' }));
    try testing.expectEqual(@as(?u32, 0x44), font.lookupSequence(&.{ 'f', 'i', 'o', 'o' }));
    // Unmapped prefix.
    try testing.expectEqual(@as(?u32, null), font.lookupSequence(&.{'z'}));
    try testing.expectEqual(@as(?u32, null), font.lookupSequence(&.{}));
}

test "psf1: 512-glyph mode" {
    const allocator = testing.allocator;
    const bytes = try buildPsf1(allocator, 512);
    defer allocator.free(bytes);

    var font = try PsfFont.parse(allocator, bytes);
    defer font.deinit();

    try testing.expectEqual(@as(u32, 512), font.glyph_count);
    var alpha: [8 * 16]u8 = undefined;
    try font.renderGlyph(511, &alpha);
}

test "psf2: header, UTF-8 table and raster" {
    const allocator = testing.allocator;

    // Entries are positional: 'A', 'e-acute', the "fi" sequence, U+FFFD.
    const table = [_]u8{
        0x41, 0xFF,
        0xC3, 0xA9, 0xFF,
        0xFE, 0x66, 0x69, 0xFF,
        0xEF, 0xBF, 0xBD, 0xFF,
    };
    const bytes = try buildPsf2(allocator, 8, 16, 4, 0x01, &table);
    defer allocator.free(bytes);

    var font = try PsfFont.parse(allocator, bytes);
    defer font.deinit();

    try testing.expectEqual(@as(u16, 8), font.width);
    try testing.expectEqual(@as(u16, 16), font.height);
    try testing.expectEqual(@as(u32, 4), font.glyph_count);
    try testing.expectEqual(@as(usize, 16), font.charsize);

    try testing.expectEqual(@as(?u32, 0), font.lookupCodepoint('A'));
    try testing.expectEqual(@as(?u32, 1), font.lookupCodepoint(0x00E9));
    try testing.expectEqual(@as(?u32, null), font.lookupCodepoint('f'));
    try testing.expectEqual(@as(?u32, 2), font.lookupSequence(&.{ 'f', 'i' }));
    try testing.expectEqual(@as(?u32, 3), font.lookupCodepoint(0xFFFD));
    try testing.expectEqual(@as(?u32, null), font.lookupCodepoint('z'));

    // Glyph 0 has row 0's low byte set; glyph 1 alternates 0x0F per row.
    var alpha: [8 * 16]u8 = undefined;
    try font.renderGlyph(0, &alpha);
    try testing.expectEqual(@as(u8, 255), alpha[0]);
    try testing.expectEqual(@as(u8, 255), alpha[7]);
    try testing.expectEqual(@as(u8, 0), alpha[8]);
    try testing.expectEqual(@as(u8, 0), alpha[15]);

    try font.renderGlyph(1, &alpha);
    // Row 0 == 0x0F: rightmost four pixels lit.
    try testing.expectEqual(@as(u8, 0), alpha[0]);
    try testing.expectEqual(@as(u8, 255), alpha[4]);
}

test "psf2: wide glyphs use ceil(width/8) stride" {
    const allocator = testing.allocator;
    const bytes = try buildPsf2(allocator, 16, 16, 1, 0, &.{});
    defer allocator.free(bytes);

    var font = try PsfFont.parse(allocator, bytes);
    defer font.deinit();

    try testing.expectEqual(@as(u16, 16), font.width);
    try testing.expectEqual(@as(usize, 32), font.charsize);

    var alpha: [16 * 16]u8 = undefined;
    try font.renderGlyph(0, &alpha);
    // Only the first byte of row 0 is set: pixels 0..7 lit, 8..15 clear.
    for (0..8) |x| try testing.expectEqual(@as(u8, 255), alpha[x]);
    for (8..16) |x| try testing.expectEqual(@as(u8, 0), alpha[x]);
    // Row 1 is entirely clear.
    for (16..32) |i| try testing.expectEqual(@as(u8, 0), alpha[i]);
}

test "gzip-wrapped PSF2 parses transparently" {
    const allocator = testing.allocator;
    const table = [_]u8{ 0x41, 0xFF, 0x42, 0xFF };
    const plain = try buildPsf2(allocator, 8, 16, 2, 0x01, &table);
    defer allocator.free(plain);

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&out.writer, &window, .gzip, .fastest);
    try compressor.writer.writeAll(plain);
    try compressor.finish();
    const gzipped = out.written();
    try testing.expect(gzipped.len >= 2);
    try testing.expectEqual(@as(u8, 0x1f), gzipped[0]);
    try testing.expectEqual(@as(u8, 0x8b), gzipped[1]);

    var font = try PsfFont.parse(allocator, gzipped);
    defer font.deinit();

    try testing.expectEqual(@as(u32, 2), font.glyph_count);
    try testing.expectEqual(@as(?u32, 0), font.lookupCodepoint('A'));
    try testing.expectEqual(@as(?u32, 1), font.lookupCodepoint('B'));

    var alpha: [8 * 16]u8 = undefined;
    try font.renderGlyph(0, &alpha);
    try testing.expectEqual(@as(u8, 255), alpha[0]);
    try testing.expectEqual(@as(u8, 0), alpha[16]);
}

test "rejects malformed input" {
    const allocator = testing.allocator;

    try testing.expectError(error.TruncatedHeader, PsfFont.parse(allocator, &.{ 0x36, 0x04 }));
    try testing.expectError(error.InvalidMagic, PsfFont.parse(allocator, "not a font"));

    // PSF1 header promising glyph data that is not there.
    try testing.expectError(
        error.TruncatedGlyphData,
        PsfFont.parse(allocator, &.{ 0x36, 0x04, 0x00, 0x10, 0, 0, 0, 0 }),
    );

    // PSF2 with zero glyphs.
    var header: [32]u8 = @splat(0);
    @memcpy(header[0..4], &psf2_magic);
    std.mem.writeInt(u32, header[8..12], 32, .little);
    std.mem.writeInt(u32, header[16..20], 0, .little);
    std.mem.writeInt(u32, header[20..24], 16, .little);
    std.mem.writeInt(u32, header[24..28], 16, .little);
    std.mem.writeInt(u32, header[28..32], 8, .little);
    try testing.expectError(error.NoGlyphs, PsfFont.parse(allocator, &header));

    // Truncated gzip stream.
    try testing.expectError(
        error.CorruptCompression,
        PsfFont.parse(allocator, &.{ 0x1f, 0x8b, 0x08, 0x00, 0x00 }),
    );
}