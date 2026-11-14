//! src/font/stbir.zig -- vendored port of the `stbir_resize_uint8` code path
//! from ghostty v1.4.0's src/stb/stb_image_resize.h (nothings/stb, public
//! domain). ghostty resizes constrained bitmap glyphs (emoji) with exactly
//! this call:
//!
//!     stbir_resize_uint8(src, w0, h0, pitch0, dst, w, h, pitch, 4)
//!
//! which fixes every option this port implements:
//!
//!   * datatype UINT8, colorspace LINEAR (the gamma-encoded premultiplied
//!     bytes are resampled directly, NO sRGB conversion),
//!   * alpha_channel = -1 -> ALPHA_PREMULTIPLIED | ALPHA_USES_COLORSPACE:
//!     all four channels are resampled identically, no unpremultiply,
//!   * edge CLAMP on both axes,
//!   * filter DEFAULT: Mitchell-Netrevalli B=C=1/3 when downsampling,
//!     Catmull-Rom when upsampling (scale > 1).
//!
//! The port keeps stb's exact f32 arithmetic and operation order (decode ->
//! horizontal resample -> ring buffer -> vertical resample -> encode),
//! including its coefficient normalization and the `(int)(v + 0.5)` encode
//! rounding (the +0.5 happens in f64, like C's float+double promotion).
//! Do not "optimize" the accumulation order or fuse multiply-adds: the
//! output must stay byte-identical to the C library.
//!
//! Only the paths listed above are ported; other stb features (sRGB
//! conversion, other edge modes, other datatypes) are intentionally absent.

const std = @import("std");

pub const Error = error{
    OutOfMemory,
    /// Zero dimensions, channels outside 1..4, or a stride smaller than
    /// one row.
    InvalidDimensions,
};

/// Downsample filter: Mitchell-Netrevalli with B=C=1/3
/// (STBIR_DEFAULT_FILTER_DOWNSAMPLE).
fn mitchell(x: f32) f32 {
    const ax = @abs(x);
    if (ax < 1.0) return (16.0 + ax * ax * (21.0 * ax - 36.0)) / 18.0;
    if (ax < 2.0) return (32.0 + ax * (-60.0 + ax * (36.0 - 7.0 * ax))) / 18.0;
    return 0.0;
}

/// Upsample filter: Catmull-Rom (STBIR_DEFAULT_FILTER_UPSAMPLE).
fn catmullrom(x: f32) f32 {
    const ax = @abs(x);
    if (ax < 1.0) return 1.0 - ax * ax * (2.5 - 1.5 * ax);
    if (ax < 2.0) return 2.0 - ax * (4.0 + ax * (0.5 * ax - 2.5));
    return 0.0;
}

const Filter = enum {
    mitchell,
    catmullrom,

    fn kernel(self: Filter, x: f32) f32 {
        return switch (self) {
            .mitchell => mitchell(x),
            .catmullrom => catmullrom(x),
        };
    }

    /// stbir__support_two: both kernels have support 2 regardless of scale.
    fn support(self: Filter) f32 {
        _ = self;
        return 2.0;
    }
};

fn useUpsampling(ratio: f32) bool {
    return ratio > 1.0;
}

/// stbir__get_filter_pixel_width.
fn filterPixelWidth(filter: Filter, scale: f32) i32 {
    return if (useUpsampling(scale))
        @intFromFloat(@ceil(filter.support() * 2.0))
    else
        @intFromFloat(@ceil(filter.support() * 2.0 / scale));
}

/// stbir__get_filter_pixel_margin.
fn filterPixelMargin(filter: Filter, scale: f32) i32 {
    return @divTrunc(filterPixelWidth(filter, scale), 2);
}

/// stbir__get_coefficient_width.
fn coefficientWidth(filter: Filter, scale: f32) i32 {
    return if (useUpsampling(scale))
        @intFromFloat(@ceil(filter.support() * 2.0))
    else
        @intFromFloat(@ceil(filter.support() * 2.0));
}

/// stbir__contributors: the output pixels an input pixel contributes to
/// (downsample) or the input pixels an output pixel samples (upsample).
const Contributor = struct { n0: i32, n1: i32 };

/// One resampling axis: filter state plus the precomputed contributor
/// table. `stride` is the allocated coefficient group width; it carries one
/// slack slot past stb's `width` so a floating-point edge case that yields
/// one extra contributor cannot scribble into the next group (stb tolerates
/// the same case through its flat temp allocation). The logical `width`
/// still bounds every loop exactly like stb.
const Axis = struct {
    filter: Filter,
    scale: f32,
    shift: f32,
    input_size: i32,
    output_size: i32,
    width: i32,
    stride: i32,
    margin: i32,
    contributors: []Contributor,
    coefficients: []f32,

    fn coeff(self: *const Axis, n: i32, c: i32) *f32 {
        return &self.coefficients[@intCast(n * self.stride + c)];
    }

    fn coeffVal(self: *const Axis, n: i32, c: i32) f32 {
        return self.coefficients[@intCast(n * self.stride + c)];
    }
};

const SampleRange = struct {
    first: i32,
    last: i32,
    center: f32,
};

/// stbir__calculate_sample_range_upsample.
fn sampleRangeUpsample(n: i32, out_filter_radius: f32, scale: f32, shift: f32) SampleRange {
    const out_pixel_center = @as(f32, @floatFromInt(n)) + 0.5;
    const lower = out_pixel_center - out_filter_radius;
    const upper = out_pixel_center + out_filter_radius;
    const in_lower = (lower + shift) / scale;
    const in_upper = (upper + shift) / scale;
    return .{
        .center = (out_pixel_center + shift) / scale,
        .first = @intFromFloat(@floor(in_lower + 0.5)),
        .last = @intFromFloat(@floor(in_upper - 0.5)),
    };
}

/// stbir__calculate_sample_range_downsample.
fn sampleRangeDownsample(n: i32, in_pixels_radius: f32, scale: f32, shift: f32) SampleRange {
    const in_pixel_center = @as(f32, @floatFromInt(n)) + 0.5;
    const lower = in_pixel_center - in_pixels_radius;
    const upper = in_pixel_center + in_pixels_radius;
    const out_lower = lower * scale - shift;
    const out_upper = upper * scale - shift;
    return .{
        .center = in_pixel_center * scale - shift,
        .first = @intFromFloat(@floor(out_lower + 0.5)),
        .last = @intFromFloat(@floor(out_upper - 0.5)),
    };
}

/// stbir__calculate_coefficients_upsample.
fn coefficientsUpsample(axis: *Axis, n: i32, range: SampleRange) void {
    var first = range.first;
    const last = range.last;
    const contrib = &axis.contributors[@intCast(n)];
    contrib.n0 = first;
    contrib.n1 = last;

    var total: f32 = 0;
    var i: i32 = 0;
    while (i <= last - first) : (i += 1) {
        const in_pixel_center = @as(f32, @floatFromInt(i + first)) + 0.5;
        const c = axis.filter.kernel(range.center - in_pixel_center);
        axis.coeff(n, i).* = c;
        // Skip leading zero coefficients (the i == 0 re-check after the
        // increment mirrors stb's i--; continue).
        if (i == 0 and c == 0) {
            first += 1;
            contrib.n0 = first;
            i -= 1;
            continue;
        }
        total += c;
    }

    // Normalize so the coefficients sum to 1.
    const filter_scale = 1.0 / total;
    i = 0;
    while (i <= last - first) : (i += 1) {
        axis.coeff(n, i).* *= filter_scale;
    }

    // Trim trailing zeros.
    i = last - first;
    while (i >= 0) : (i -= 1) {
        if (axis.coeffVal(n, i) != 0) break;
        contrib.n1 = contrib.n0 + i - 1;
    }
}

/// stbir__calculate_coefficients_downsample.
fn coefficientsDownsample(axis: *Axis, n: i32, range: SampleRange) void {
    const first = range.first;
    const last = range.last;
    const contrib = &axis.contributors[@intCast(n)];
    contrib.n0 = first;
    contrib.n1 = last;

    var i: i32 = 0;
    while (i <= last - first) : (i += 1) {
        const out_pixel_center = @as(f32, @floatFromInt(i + first)) + 0.5;
        const x = out_pixel_center - range.center;
        axis.coeff(n, i).* = axis.filter.kernel(x) * axis.scale;
    }

    // Trim trailing zeros.
    i = last - first;
    while (i >= 0) : (i -= 1) {
        if (axis.coeffVal(n, i) != 0) break;
        contrib.n1 = contrib.n0 + i - 1;
    }
}

/// stbir__normalize_downsample_coefficients: per-output-pixel
/// normalization, then zero/negative skip compaction, then n1 clamp.
fn normalizeDownsample(axis: *Axis) void {
    const num_contributors: i32 = @intCast(axis.contributors.len);
    const output_size = axis.output_size;

    var i: i32 = 0;
    while (i < output_size) : (i += 1) {
        var total: f32 = 0;
        var j: i32 = 0;
        while (j < num_contributors) : (j += 1) {
            const c = &axis.contributors[@intCast(j)];
            if (i >= c.n0 and i <= c.n1) {
                total += axis.coeffVal(j, i - c.n0);
            } else if (i < c.n0) break;
        }
        const scale = 1.0 / total;
        j = 0;
        while (j < num_contributors) : (j += 1) {
            const c = &axis.contributors[@intCast(j)];
            if (i >= c.n0 and i <= c.n1) {
                axis.coeff(j, i - c.n0).* *= scale;
            } else if (i < c.n0) break;
        }
    }

    // Skip zero coefficients and contributions outside the image bounds.
    // Done after normalization because normalization depends on n0/n1.
    var j: i32 = 0;
    while (j < num_contributors) : (j += 1) {
        const c = &axis.contributors[@intCast(j)];
        var skip: i32 = 0;
        while (skip < axis.stride and axis.coeffVal(j, skip) == 0) : (skip += 1) {}
        c.n0 += skip;
        while (c.n0 < 0) {
            c.n0 += 1;
            skip += 1;
        }
        const range = c.n1 - c.n0 + 1;
        const max = @min(axis.width, range);
        var k: i32 = 0;
        while (k < max) : (k += 1) {
            if (k + skip >= axis.width) break;
            axis.coeff(j, k).* = axis.coeffVal(j, k + skip);
        }
    }

    for (axis.contributors) |*c| {
        c.n1 = @min(c.n1, output_size - 1);
    }
}

/// stbir__calculate_filters.
fn calculateFilters(axis: *Axis) void {
    const n_contributors: i32 = @intCast(axis.contributors.len);
    if (useUpsampling(axis.scale)) {
        const out_pixels_radius = axis.filter.support() * axis.scale;
        var n: i32 = 0;
        while (n < n_contributors) : (n += 1) {
            const range = sampleRangeUpsample(n, out_pixels_radius, axis.scale, axis.shift);
            coefficientsUpsample(axis, n, range);
        }
    } else {
        const in_pixels_radius = axis.filter.support() / axis.scale;
        var n: i32 = 0;
        while (n < n_contributors) : (n += 1) {
            const n_adjusted = n - axis.margin;
            const range = sampleRangeDownsample(n_adjusted, in_pixels_radius, axis.scale, axis.shift);
            coefficientsDownsample(axis, n, range);
        }
        normalizeDownsample(axis);
    }
}

const Info = struct {
    input_w: i32,
    input_h: i32,
    output_w: i32,
    output_h: i32,
    channels: i32,
    input: []const u8,
    input_stride: usize,
    output: []u8,
    output_stride: usize,
    h: Axis,
    v: Axis,
    /// Decoded scanline with `h.margin` clamped pixels on each side.
    decode_buffer: []f32,
    /// Horizontally resampled scanline (height-downsample path only).
    horizontal_buffer: []f32,
    /// Ring of horizontally resampled scanlines.
    ring: []f32,
    ring_entries: i32,
    ring_begin: i32 = -1,
    ring_first: i32 = 0,
    ring_last: i32 = 0,
    /// Vertical accumulation buffer (height-upsample path only).
    encode_buffer: []f32,

    fn ringRowLen(self: *const Info) usize {
        return @intCast(self.output_w * self.channels);
    }

    /// stbir__get_decode_buffer: index 0 is the first real pixel, so
    /// negative pixel indices (the left margin) stay in bounds.
    fn decodeAt(self: *const Info, pixel: i32) []f32 {
        const base: usize = @intCast((pixel + self.h.margin) * self.channels);
        return self.decode_buffer[base..][0..@intCast(self.channels)];
    }

    fn ringEntry(self: *const Info, index: i32) []f32 {
        const len = self.ringRowLen();
        const base: usize = @as(usize, @intCast(index)) * len;
        return self.ring[base..][0..len];
    }

    /// stbir__get_ring_buffer_scanline.
    fn ringScanline(self: *const Info, scanline: i32) []f32 {
        const index = @mod(self.ring_begin + (scanline - self.ring_first), self.ring_entries);
        return self.ringEntry(index);
    }

    /// stbir__add_empty_ring_buffer_entry.
    fn addEmptyRingEntry(self: *Info, n: i32) []f32 {
        self.ring_last = n;
        var index: i32 = undefined;
        if (self.ring_begin < 0) {
            self.ring_begin = 0;
            index = 0;
            self.ring_first = n;
        } else {
            index = @mod(self.ring_begin + (self.ring_last - self.ring_first), self.ring_entries);
        }
        const entry = self.ringEntry(index);
        @memset(entry, 0);
        return entry;
    }
};

/// stbir__decode_scanline for UINT8/LINEAR with CLAMP edges: byte/255.0f,
/// no colorspace conversion, all channels identical.
fn decodeScanline(info: *Info, n: i32) void {
    const row: usize = @intCast(std.math.clamp(n, 0, info.input_h - 1));
    const src = info.input[row * info.input_stride ..];
    const ch: usize = @intCast(info.channels);
    const max_x = info.input_w + info.h.margin;
    var x: i32 = -info.h.margin;
    while (x < max_x) : (x += 1) {
        const sx: usize = @intCast(std.math.clamp(x, 0, info.input_w - 1));
        const dst = info.decodeAt(x);
        for (0..ch) |c| {
            dst[c] = @as(f32, @floatFromInt(src[sx * ch + c])) / 255.0;
        }
    }
}

/// stbir__resample_horizontal_upsample (generic-channel loop; stb's
/// unrolled case 4 performs the same operations in the same order).
fn resampleHorizontalUpsample(info: *Info, out: []f32) void {
    const ch: usize = @intCast(info.channels);
    var x: i32 = 0;
    while (x < info.output_w) : (x += 1) {
        const c = &info.h.contributors[@intCast(x)];
        const out_base: usize = @intCast(x * info.channels);
        var k = c.n0;
        while (k <= c.n1) : (k += 1) {
            const coefficient = info.h.coeffVal(x, k - c.n0);
            const in_px = info.decodeAt(k);
            for (0..ch) |cc| {
                out[out_base + cc] += in_px[cc] * coefficient;
            }
        }
    }
}

/// stbir__resample_horizontal_downsample.
fn resampleHorizontalDownsample(info: *Info, out: []f32) void {
    const ch: usize = @intCast(info.channels);
    const max_x = info.input_w + info.h.margin * 2;
    var x: i32 = 0;
    while (x < max_x) : (x += 1) {
        const c = &info.h.contributors[@intCast(x)];
        const in_base: usize = @intCast(x * info.channels);
        var k = c.n0;
        while (k <= c.n1) : (k += 1) {
            const coefficient = info.h.coeffVal(x, k - c.n0);
            const out_base: usize = @intCast(k * info.channels);
            for (0..ch) |cc| {
                out[out_base + cc] += info.decode_buffer[in_base + cc] * coefficient;
            }
        }
    }
}

fn horizontalResample(info: *Info, out: []f32) void {
    if (useUpsampling(info.h.scale))
        resampleHorizontalUpsample(info, out)
    else
        resampleHorizontalDownsample(info, out);
}

/// stbir__encode_scanline for UINT8/LINEAR with ALPHA_PREMULTIPLIED and
/// ALPHA_USES_COLORSPACE: every channel is encoded directly, no
/// unpremultiply and no colorspace conversion. STBIR__ENCODE_LINEAR8 is
/// (unsigned char)(int)(saturate(f) * 255.0f + 0.5); the +0.5 promotes to
/// double in C, so it is done in f64 here.
fn encodeScanline(row: []u8, buf: []const f32) void {
    for (row, 0..) |*dst, i| {
        const f = std.math.clamp(buf[i], 0.0, 1.0);
        const v: f32 = f * 255.0;
        dst.* = @intFromFloat(@as(f64, v) + 0.5);
    }
}

/// stbir__resample_vertical_upsample: accumulate the ring scanlines into
/// the encode buffer, then encode one output row.
fn resampleVerticalUpsample(info: *Info, n: i32) void {
    const c = &info.v.contributors[@intCast(n)];
    @memset(info.encode_buffer, 0);
    var k = c.n0;
    while (k <= c.n1) : (k += 1) {
        const coefficient = info.v.coeffVal(n, k - c.n0);
        const ring_row = info.ringScanline(k);
        for (info.encode_buffer, 0..) |*dst, i| {
            dst.* += ring_row[i] * coefficient;
        }
    }
    const row_base: usize = @as(usize, @intCast(n)) * info.output_stride;
    encodeScanline(info.output[row_base..][0..@intCast(info.output_w * info.channels)], info.encode_buffer);
}

/// stbir__resample_vertical_downsample: distribute the horizontal buffer
/// into the ring scanlines this input row contributes to.
fn resampleVerticalDownsample(info: *Info, n: i32) void {
    const contributor = n + info.v.margin;
    const c = &info.v.contributors[@intCast(contributor)];
    var k = c.n0;
    while (k <= c.n1) : (k += 1) {
        const coefficient = info.v.coeffVal(contributor, k - c.n0);
        const ring_row = info.ringScanline(k);
        for (ring_row, 0..) |*dst, i| {
            dst.* += info.horizontal_buffer[i] * coefficient;
        }
    }
}

/// stbir__decode_and_resample_upsample.
fn decodeAndResampleUpsample(info: *Info, n: i32) void {
    decodeScanline(info, n);
    const entry = info.addEmptyRingEntry(n);
    horizontalResample(info, entry);
}

/// stbir__buffer_loop_upsample.
fn bufferLoopUpsample(info: *Info) void {
    const out_scanlines_radius = info.v.filter.support() * info.v.scale;
    var y: i32 = 0;
    while (y < info.output_h) : (y += 1) {
        const range = sampleRangeUpsample(y, out_scanlines_radius, info.v.scale, info.v.shift);
        if (info.ring_begin >= 0) {
            while (range.first > info.ring_first) {
                if (info.ring_first == info.ring_last) {
                    info.ring_begin = -1;
                    info.ring_first = 0;
                    info.ring_last = 0;
                    break;
                } else {
                    info.ring_first += 1;
                    info.ring_begin = @mod(info.ring_begin + 1, info.ring_entries);
                }
            }
        }
        if (info.ring_begin < 0)
            decodeAndResampleUpsample(info, range.first);
        while (range.last > info.ring_last)
            decodeAndResampleUpsample(info, info.ring_last + 1);
        resampleVerticalUpsample(info, y);
    }
}

/// stbir__empty_ring_buffer: encode every completed output row below
/// `first_necessary` and drop it from the ring.
fn emptyRingBuffer(info: *Info, first_necessary: i32) void {
    if (info.ring_begin < 0) return;
    while (first_necessary > info.ring_first) {
        if (info.ring_first >= 0 and info.ring_first < info.output_h) {
            const row_base: usize = @as(usize, @intCast(info.ring_first)) * info.output_stride;
            const entry = info.ringEntry(info.ring_begin);
            encodeScanline(info.output[row_base..][0..@intCast(info.output_w * info.channels)], entry);
        }
        if (info.ring_first == info.ring_last) {
            info.ring_begin = -1;
            info.ring_first = 0;
            info.ring_last = 0;
            break;
        } else {
            info.ring_first += 1;
            info.ring_begin = @mod(info.ring_begin + 1, info.ring_entries);
        }
    }
}

/// stbir__buffer_loop_downsample.
fn bufferLoopDownsample(info: *Info) void {
    const in_pixels_radius = info.v.filter.support() / info.v.scale;
    const max_y = info.input_h + info.v.margin;
    var y: i32 = -info.v.margin;
    while (y < max_y) : (y += 1) {
        const range = sampleRangeDownsample(y, in_pixels_radius, info.v.scale, info.v.shift);
        if (range.last < 0 or range.first >= info.output_h) continue;
        emptyRingBuffer(info, range.first);
        decodeScanline(info, y);
        @memset(info.horizontal_buffer, 0);
        horizontalResample(info, info.horizontal_buffer);
        if (info.ring_begin < 0)
            _ = info.addEmptyRingEntry(range.first);
        while (range.last > info.ring_last)
            _ = info.addEmptyRingEntry(info.ring_last + 1);
        resampleVerticalDownsample(info, y);
    }
    emptyRingBuffer(info, info.output_h);
}

fn initAxis(alloc: std.mem.Allocator, filter: Filter, scale: f32, input_size: i32, output_size: i32) Error!Axis {
    const width = coefficientWidth(filter, scale);
    const margin = filterPixelMargin(filter, scale);
    const num_contributors: usize = @intCast(if (useUpsampling(scale))
        output_size
    else
        input_size + margin * 2);
    const stride = width + 1; // one slack slot, see Axis
    const contributors = try alloc.alloc(Contributor, num_contributors);
    errdefer alloc.free(contributors);
    const coefficients = try alloc.alloc(f32, num_contributors * @as(usize, @intCast(stride)));
    @memset(coefficients, 0);
    return .{
        .filter = filter,
        .scale = scale,
        .shift = 0,
        .input_size = input_size,
        .output_size = output_size,
        .width = width,
        .stride = stride,
        .margin = margin,
        .contributors = contributors,
        .coefficients = coefficients,
    };
}


/// Resize tightly-or-strided packed UINT8 pixels with `channels` channels
/// (1..4), the exact stbir_resize_uint8 pipeline described in the module
/// comment. `output` must hold output_stride * output_h bytes. All
/// intermediate buffers are zeroed like stb's memset of its temp block.
pub fn resizeUint8(
    alloc: std.mem.Allocator,
    input: []const u8,
    input_w: u32,
    input_h: u32,
    input_stride: u32,
    output: []u8,
    output_w: u32,
    output_h: u32,
    output_stride: u32,
    channels: u32,
) Error!void {
    if (input_w == 0 or input_h == 0 or output_w == 0 or output_h == 0 or
        channels == 0 or channels > 4) return Error.InvalidDimensions;
    if (input_stride < input_w * channels or output_stride < output_w * channels)
        return Error.InvalidDimensions;
    if (input.len < @as(usize, input_stride) * input_h) return Error.InvalidDimensions;
    if (output.len < @as(usize, output_stride) * output_h) return Error.InvalidDimensions;

    const iw: i32 = @intCast(input_w);
    const ih: i32 = @intCast(input_h);
    const ow: i32 = @intCast(output_w);
    const oh: i32 = @intCast(output_h);
    const chi: i32 = @intCast(channels);

    // stbir__calculate_transform with s0=t0=0, s1=t1=1.
    const h_scale = @as(f32, @floatFromInt(ow)) / @as(f32, @floatFromInt(iw));
    const v_scale = @as(f32, @floatFromInt(oh)) / @as(f32, @floatFromInt(ih));
    // stbir__choose_filter with STBIR_FILTER_DEFAULT.
    const h_filter: Filter = if (useUpsampling(h_scale)) .catmullrom else .mitchell;
    const v_filter: Filter = if (useUpsampling(v_scale)) .catmullrom else .mitchell;

    // All intermediate buffers share one arena: a single cleanup point,
    // no per-buffer error unwinding (stb uses one flat temp block too).
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var info: Info = .{
        .input_w = iw,
        .input_h = ih,
        .output_w = ow,
        .output_h = oh,
        .channels = chi,
        .input = input,
        .input_stride = input_stride,
        .output = output,
        .output_stride = output_stride,
        .h = try initAxis(a, h_filter, h_scale, iw, ow),
        .v = try initAxis(a, v_filter, v_scale, ih, oh),
        .decode_buffer = undefined,
        .horizontal_buffer = &.{},
        .ring = undefined,
        .ring_entries = filterPixelWidth(v_filter, v_scale) + 1,
        .encode_buffer = &.{},
    };

    const decode_len: usize = @intCast((iw + info.h.margin * 2) * chi);
    info.decode_buffer = try a.alloc(f32, decode_len);
    @memset(info.decode_buffer, 0);

    const row_len: usize = @intCast(ow * chi);
    const v_up = useUpsampling(v_scale);
    if (!v_up) {
        info.horizontal_buffer = try a.alloc(f32, row_len);
        @memset(info.horizontal_buffer, 0);
    }
    info.ring = try a.alloc(f32, row_len * @as(usize, @intCast(info.ring_entries)));
    @memset(info.ring, 0);
    if (v_up) {
        info.encode_buffer = try a.alloc(f32, row_len);
        @memset(info.encode_buffer, 0);
    }

    calculateFilters(&info.h);
    calculateFilters(&info.v);

    if (v_up)
        bufferLoopUpsample(&info)
    else
        bufferLoopDownsample(&info);
}

// ---------------------------------------------------------------------------
// Tests: pure, no fonts. The byte-exact reference is the C library itself
// (verified out-of-tree against ghostty's vendored stb_image_resize.h).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "stbir: identity-size resize stays close to the source" {
    // scale == 1 takes the downsample (Mitchell) path like stb; a constant
    // image must survive any filter exactly.
    const alloc = testing.allocator;
    const w = 8;
    const h = 6;
    var src: [w * h * 4]u8 = undefined;
    // Make it constant per channel so normalization cannot shift values.
    for (&src, 0..) |*b, i| b.* = @intCast((i % 4) * 60);
    var dst: [w * h * 4]u8 = undefined;
    try resizeUint8(alloc, &src, w, h, w * 4, &dst, w, h, w * 4, 4);
    try testing.expectEqualSlices(u8, &src, &dst);
}

test "stbir: solid color survives downscale and upscale" {
    const alloc = testing.allocator;
    var src: [16 * 16 * 4]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = switch (i % 4) {
        0 => 10,
        1 => 20,
        2 => 30,
        else => 255,
    };
    var down: [4 * 4 * 4]u8 = undefined;
    try resizeUint8(alloc, &src, 16, 16, 16 * 4, &down, 4, 4, 4 * 4, 4);
    for (down, 0..) |b, i| try testing.expectEqual(src[i % 4], b);
    var up: [32 * 32 * 4]u8 = undefined;
    try resizeUint8(alloc, &src, 16, 16, 16 * 4, &up, 32, 32, 32 * 4, 4);
    for (up, 0..) |b, i| try testing.expectEqual(src[i % 4], b);
}

test "stbir: rejects invalid dimensions" {
    const alloc = testing.allocator;
    var buf: [16]u8 = undefined;
    try testing.expectError(Error.InvalidDimensions, resizeUint8(alloc, &buf, 0, 1, 4, &buf, 1, 1, 4, 4));
    try testing.expectError(Error.InvalidDimensions, resizeUint8(alloc, &buf, 1, 1, 4, &buf, 1, 1, 4, 5));
    try testing.expectError(Error.InvalidDimensions, resizeUint8(alloc, &buf, 2, 1, 4, &buf, 1, 1, 4, 4));
}
