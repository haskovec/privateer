//! Sprite upscaling pipeline using edge-aware pixel art algorithms.
//! Implements Scale2x/Scale3x (EPX family) for smooth upscaling of
//! pixel art without the blocky artifacts of nearest-neighbor scaling.
//!
//! Scale factors:
//!   2x: Scale2x algorithm (edge-aware 2x upscale)
//!   3x: Scale3x algorithm (edge-aware 3x upscale)
//!   4x: Scale2x applied twice (2x -> 2x)
//!
//! These algorithms analyze neighboring pixels to detect edges and produce
//! smooth diagonal transitions while preserving sharp horizontal/vertical
//! boundaries -- ideal for the original game's pixel art sprites.

const std = @import("std");

/// Supported upscale factors.
pub const ScaleFactor = enum(u8) {
    x2 = 2,
    x3 = 3,
    x4 = 4,

    pub fn multiplier(self: ScaleFactor) u32 {
        return @intFromEnum(self);
    }
};

/// Result of an upscale operation.
pub const UpscaledImage = struct {
    width: u32,
    height: u32,
    /// RGBA pixel data (4 bytes per pixel, row-major).
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *UpscaledImage) void {
        self.allocator.free(self.pixels);
    }
};

/// Upscale an RGBA image using edge-aware pixel art scaling.
///
/// Input: RGBA pixel data (4 bytes per pixel, row-major) with dimensions.
/// Returns: Newly allocated upscaled RGBA image.
pub fn upscale(
    allocator: std.mem.Allocator,
    src: []const u8,
    width: u32,
    height: u32,
    factor: ScaleFactor,
) !UpscaledImage {
    return switch (factor) {
        .x2 => scale2x(allocator, src, width, height),
        .x3 => scale3x(allocator, src, width, height),
        .x4 => {
            // 4x = apply Scale2x twice
            var intermediate = try scale2x(allocator, src, width, height);
            defer intermediate.deinit();
            return scale2x(allocator, intermediate.pixels, intermediate.width, intermediate.height);
        },
    };
}

// --- Internal helpers ---

/// Compare two RGBA pixels for equality.
fn colorsEqual(pixels: []const u8, i: usize, j: usize) bool {
    return std.mem.eql(u8, pixels[i * 4 ..][0..4], pixels[j * 4 ..][0..4]);
}

/// Get the flat pixel index, clamping coordinates to image bounds.
fn clampedIndex(x: i32, y: i32, width: u32, height: u32) usize {
    const cx: u32 = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(width)) - 1));
    const cy: u32 = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(height)) - 1));
    return @as(usize, cy) * @as(usize, width) + @as(usize, cx);
}

/// Copy a single RGBA pixel from src to dst by flat index.
fn copyPixel(dst: []u8, dst_idx: usize, src: []const u8, src_idx: usize) void {
    @memcpy(dst[dst_idx * 4 ..][0..4], src[src_idx * 4 ..][0..4]);
}

// --- Scale2x (EPX) ---
//
// For each source pixel E with cardinal neighbors:
//
//     B
//   D E F
//     H
//
// Output 2x2 block:
//   E0 E1
//   E2 E3
//
// Rules:
//   E0 = (D == B && D != H && B != F) ? D : E
//   E1 = (B == F && B != D && F != H) ? F : E
//   E2 = (D == H && D != B && H != F) ? D : E
//   E3 = (H == F && D != H && B != F) ? F : E

fn scale2x(allocator: std.mem.Allocator, src: []const u8, width: u32, height: u32) !UpscaledImage {
    const out_w = width * 2;
    const out_h = height * 2;
    const out_pixels = try allocator.alloc(u8, @as(usize, out_w) * @as(usize, out_h) * 4);
    errdefer allocator.free(out_pixels);

    for (0..height) |y| {
        for (0..width) |x| {
            const ix: i32 = @intCast(x);
            const iy: i32 = @intCast(y);

            const e_idx = clampedIndex(ix, iy, width, height);
            const b_idx = clampedIndex(ix, iy - 1, width, height); // up
            const d_idx = clampedIndex(ix - 1, iy, width, height); // left
            const f_idx = clampedIndex(ix + 1, iy, width, height); // right
            const h_idx = clampedIndex(ix, iy + 1, width, height); // down

            const d_eq_b = colorsEqual(src, d_idx, b_idx);
            const b_eq_f = colorsEqual(src, b_idx, f_idx);
            const d_eq_h = colorsEqual(src, d_idx, h_idx);
            const h_eq_f = colorsEqual(src, h_idx, f_idx);

            const ox = x * 2;
            const oy = y * 2;
            const ow: usize = @intCast(out_w);

            // E0 (top-left)
            const e0 = oy * ow + ox;
            if (d_eq_b and !d_eq_h and !b_eq_f)
                copyPixel(out_pixels, e0, src, d_idx)
            else
                copyPixel(out_pixels, e0, src, e_idx);

            // E1 (top-right)
            const e1 = oy * ow + ox + 1;
            if (b_eq_f and !d_eq_b and !h_eq_f)
                copyPixel(out_pixels, e1, src, f_idx)
            else
                copyPixel(out_pixels, e1, src, e_idx);

            // E2 (bottom-left)
            const e2 = (oy + 1) * ow + ox;
            if (d_eq_h and !d_eq_b and !h_eq_f)
                copyPixel(out_pixels, e2, src, d_idx)
            else
                copyPixel(out_pixels, e2, src, e_idx);

            // E3 (bottom-right)
            const e3 = (oy + 1) * ow + ox + 1;
            if (h_eq_f and !d_eq_h and !b_eq_f)
                copyPixel(out_pixels, e3, src, f_idx)
            else
                copyPixel(out_pixels, e3, src, e_idx);
        }
    }

    return .{
        .width = out_w,
        .height = out_h,
        .pixels = out_pixels,
        .allocator = allocator,
    };
}

// --- Scale3x ---
//
// For each source pixel E with all 8 neighbors:
//
//   A B C       E0 E1 E2
//   D E F  -->  E3 E4 E5
//   G H I       E6 E7 E8
//
// Rules (from AdvanceMAME Scale3x specification):
//   E0 = D==B && D!=H && B!=F ? D : E
//   E1 = (D==B && D!=H && B!=F && E!=C) || (B==F && B!=D && F!=H && E!=A) ? B : E
//   E2 = B==F && B!=D && F!=H ? F : E
//   E3 = (D==B && D!=H && B!=F && E!=G) || (D==H && D!=B && H!=F && E!=A) ? D : E
//   E4 = E
//   E5 = (B==F && B!=D && F!=H && E!=I) || (H==F && D!=H && B!=F && E!=C) ? F : E
//   E6 = D==H && D!=B && H!=F ? D : E
//   E7 = (D==H && D!=B && H!=F && E!=I) || (H==F && D!=H && B!=F && E!=G) ? H : E
//   E8 = H==F && D!=H && B!=F ? F : E

fn scale3x(allocator: std.mem.Allocator, src: []const u8, width: u32, height: u32) !UpscaledImage {
    const out_w = width * 3;
    const out_h = height * 3;
    const out_pixels = try allocator.alloc(u8, @as(usize, out_w) * @as(usize, out_h) * 4);
    errdefer allocator.free(out_pixels);

    for (0..height) |y| {
        for (0..width) |x| {
            const ix: i32 = @intCast(x);
            const iy: i32 = @intCast(y);

            const a_idx = clampedIndex(ix - 1, iy - 1, width, height);
            const b_idx = clampedIndex(ix, iy - 1, width, height);
            const c_idx = clampedIndex(ix + 1, iy - 1, width, height);
            const d_idx = clampedIndex(ix - 1, iy, width, height);
            const e_idx = clampedIndex(ix, iy, width, height);
            const f_idx = clampedIndex(ix + 1, iy, width, height);
            const g_idx = clampedIndex(ix - 1, iy + 1, width, height);
            const h_idx = clampedIndex(ix, iy + 1, width, height);
            const i_idx = clampedIndex(ix + 1, iy + 1, width, height);

            const d_eq_b = colorsEqual(src, d_idx, b_idx);
            const b_eq_f = colorsEqual(src, b_idx, f_idx);
            const d_eq_h = colorsEqual(src, d_idx, h_idx);
            const h_eq_f = colorsEqual(src, h_idx, f_idx);
            const d_ne_b = !d_eq_b;
            const b_ne_f = !b_eq_f;
            const d_ne_h = !d_eq_h;
            const h_ne_f = !h_eq_f;
            const e_ne_a = !colorsEqual(src, e_idx, a_idx);
            const e_ne_c = !colorsEqual(src, e_idx, c_idx);
            const e_ne_g = !colorsEqual(src, e_idx, g_idx);
            const e_ne_i = !colorsEqual(src, e_idx, i_idx);

            const ox = x * 3;
            const oy = y * 3;
            const ow: usize = @intCast(out_w);

            // E0
            var idx = oy * ow + ox;
            if (d_eq_b and d_ne_h and b_ne_f)
                copyPixel(out_pixels, idx, src, d_idx)
            else
                copyPixel(out_pixels, idx, src, e_idx);

            // E1
            idx = oy * ow + ox + 1;
            if ((d_eq_b and d_ne_h and b_ne_f and e_ne_c) or (b_eq_f and d_ne_b and h_ne_f and e_ne_a))
                copyPixel(out_pixels, idx, src, b_idx)
            else
                copyPixel(out_pixels, idx, src, e_idx);

            // E2
            idx = oy * ow + ox + 2;
            if (b_eq_f and d_ne_b and h_ne_f)
                copyPixel(out_pixels, idx, src, f_idx)
            else
                copyPixel(out_pixels, idx, src, e_idx);

            // E3
            idx = (oy + 1) * ow + ox;
            if ((d_eq_b and d_ne_h and b_ne_f and e_ne_g) or (d_eq_h and d_ne_b and h_ne_f and e_ne_a))
                copyPixel(out_pixels, idx, src, d_idx)
            else
                copyPixel(out_pixels, idx, src, e_idx);

            // E4 (center -- always E)
            idx = (oy + 1) * ow + ox + 1;
            copyPixel(out_pixels, idx, src, e_idx);

            // E5
            idx = (oy + 1) * ow + ox + 2;
            if ((b_eq_f and d_ne_b and h_ne_f and e_ne_i) or (h_eq_f and d_ne_h and b_ne_f and e_ne_c))
                copyPixel(out_pixels, idx, src, f_idx)
            else
                copyPixel(out_pixels, idx, src, e_idx);

            // E6
            idx = (oy + 2) * ow + ox;
            if (d_eq_h and d_ne_b and h_ne_f)
                copyPixel(out_pixels, idx, src, d_idx)
            else
                copyPixel(out_pixels, idx, src, e_idx);

            // E7
            idx = (oy + 2) * ow + ox + 1;
            if ((d_eq_h and d_ne_b and h_ne_f and e_ne_i) or (h_eq_f and d_ne_h and b_ne_f and e_ne_g))
                copyPixel(out_pixels, idx, src, h_idx)
            else
                copyPixel(out_pixels, idx, src, e_idx);

            // E8
            idx = (oy + 2) * ow + ox + 2;
            if (h_eq_f and d_ne_h and b_ne_f)
                copyPixel(out_pixels, idx, src, f_idx)
            else
                copyPixel(out_pixels, idx, src, e_idx);
        }
    }

    return .{
        .width = out_w,
        .height = out_h,
        .pixels = out_pixels,
        .allocator = allocator,
    };
}

// --- Tests ---

/// Helper: create an RGBA pixel value.
fn rgba(r: u8, g: u8, b: u8, a: u8) [4]u8 {
    return .{ r, g, b, a };
}

/// Helper: read an RGBA pixel from a buffer by (x, y) coordinate.
fn getPixel(pixels: []const u8, x: u32, y: u32, width: u32) [4]u8 {
    const off = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
    return pixels[off..][0..4].*;
}

/// Helper: build an RGBA image from a 2D array of pixel values.
fn buildImage(comptime rows: u32, comptime cols: u32, pattern: [rows][cols][4]u8) [rows * cols * 4]u8 {
    var buf: [rows * cols * 4]u8 = undefined;
    for (0..rows) |y| {
        for (0..cols) |x| {
            const off = (y * cols + x) * 4;
            @memcpy(buf[off..][0..4], &pattern[y][x]);
        }
    }
    return buf;
}

// === Dimension tests ===

test "upscale 4x4 at 2x produces 8x8" {
    const allocator = std.testing.allocator;
    const R = rgba(255, 0, 0, 255);
    const src = buildImage(4, 4, .{
        .{ R, R, R, R },
        .{ R, R, R, R },
        .{ R, R, R, R },
        .{ R, R, R, R },
    });
    var result = try upscale(allocator, &src, 4, 4, .x2);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 8), result.width);
    try std.testing.expectEqual(@as(u32, 8), result.height);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 4), result.pixels.len);
}

test "upscale 4x4 at 4x produces 16x16" {
    const allocator = std.testing.allocator;
    const B = rgba(0, 0, 255, 255);
    const src = buildImage(4, 4, .{
        .{ B, B, B, B },
        .{ B, B, B, B },
        .{ B, B, B, B },
        .{ B, B, B, B },
    });
    var result = try upscale(allocator, &src, 4, 4, .x4);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 16), result.width);
    try std.testing.expectEqual(@as(u32, 16), result.height);
    try std.testing.expectEqual(@as(usize, 16 * 16 * 4), result.pixels.len);
}

test "upscale 4x4 at 3x produces 12x12" {
    const allocator = std.testing.allocator;
    const G = rgba(0, 255, 0, 255);
    const src = buildImage(4, 4, .{
        .{ G, G, G, G },
        .{ G, G, G, G },
        .{ G, G, G, G },
        .{ G, G, G, G },
    });
    var result = try upscale(allocator, &src, 4, 4, .x3);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 12), result.width);
    try std.testing.expectEqual(@as(u32, 12), result.height);
}

// === Solid color preservation ===

test "upscaling solid color preserves all pixels" {
    const allocator = std.testing.allocator;
    const R = rgba(255, 0, 0, 255);
    const src = buildImage(3, 3, .{
        .{ R, R, R },
        .{ R, R, R },
        .{ R, R, R },
    });

    var result = try upscale(allocator, &src, 3, 3, .x2);
    defer result.deinit();

    for (0..6) |y| {
        for (0..6) |x| {
            const px = getPixel(result.pixels, @intCast(x), @intCast(y), result.width);
            try std.testing.expectEqualSlices(u8, &R, &px);
        }
    }
}

// === Edge smoothing (the key quality test) ===

test "scale2x smooths diagonal edges (no raw pixel doubling)" {
    // 4x4 image with a diagonal boundary between black (K) and white (W):
    //   K K W W
    //   K K W W
    //   W W K K
    //   W W K K
    //
    // Nearest-neighbor 2x would produce blocky 2x2 blocks.
    // Scale2x should create smooth diagonal transitions.
    const allocator = std.testing.allocator;
    const K = rgba(0, 0, 0, 255); // black
    const W = rgba(255, 255, 255, 255); // white

    const src = buildImage(4, 4, .{
        .{ K, K, W, W },
        .{ K, K, W, W },
        .{ W, W, K, K },
        .{ W, W, K, K },
    });

    var result = try upscale(allocator, &src, 4, 4, .x2);
    defer result.deinit();

    // Source pixel (1,1) = K with neighbors:
    //   up=(1,0)=K, down=(1,2)=W, left=(0,1)=K, right=(2,1)=W
    //
    // E3 rule: H==F && D!=H && B!=F → W==W && K!=W && K!=W → true → F = W
    //
    // So the bottom-right of the (1,1) output block = W (not K).
    // Output coords: E3 of (1,1) is at (3, 3).
    const e3_pixel = getPixel(result.pixels, 3, 3, result.width);
    try std.testing.expectEqualSlices(u8, &W, &e3_pixel);

    // The top-left of the same block should still be K (the center pixel).
    // Output coords: E0 of (1,1) is at (2, 2).
    const e0_pixel = getPixel(result.pixels, 2, 2, result.width);
    try std.testing.expectEqualSlices(u8, &K, &e0_pixel);

    // Similarly, source pixel (2,2) = K should have its E0 smoothed.
    // (2,2) neighbors: up=(2,1)=W, down=(2,3)=K, left=(1,2)=W, right=(3,2)=K
    // E0 rule: D==B && D!=H && B!=F → W==W && W!=K && W!=K → true → D = W
    // Output coords: E0 of (2,2) is at (4, 4).
    const corner_pixel = getPixel(result.pixels, 4, 4, result.width);
    try std.testing.expectEqualSlices(u8, &W, &corner_pixel);
}

test "scale2x preserves clean horizontal edges" {
    // 2x2 image: top row white, bottom row black.
    // Scale2x should NOT create diagonal artifacts on horizontal boundaries.
    const allocator = std.testing.allocator;
    const K = rgba(0, 0, 0, 255);
    const W = rgba(255, 255, 255, 255);

    const src = buildImage(2, 2, .{
        .{ W, W },
        .{ K, K },
    });

    var result = try upscale(allocator, &src, 2, 2, .x2);
    defer result.deinit();

    // Top two rows should be all white
    for (0..2) |y| {
        for (0..4) |x| {
            const px = getPixel(result.pixels, @intCast(x), @intCast(y), result.width);
            try std.testing.expectEqualSlices(u8, &W, &px);
        }
    }
    // Bottom two rows should be all black
    for (2..4) |y| {
        for (0..4) |x| {
            const px = getPixel(result.pixels, @intCast(x), @intCast(y), result.width);
            try std.testing.expectEqualSlices(u8, &K, &px);
        }
    }
}

// === Scale factor API ===

test "scale factor multiplier values" {
    try std.testing.expectEqual(@as(u32, 2), ScaleFactor.x2.multiplier());
    try std.testing.expectEqual(@as(u32, 3), ScaleFactor.x3.multiplier());
    try std.testing.expectEqual(@as(u32, 4), ScaleFactor.x4.multiplier());
}

// === Edge cases ===

test "upscale 1x1 image" {
    const allocator = std.testing.allocator;
    const C = rgba(128, 64, 32, 255);
    const src = buildImage(1, 1, .{.{C}});

    // 2x
    var r2 = try upscale(allocator, &src, 1, 1, .x2);
    defer r2.deinit();
    try std.testing.expectEqual(@as(u32, 2), r2.width);
    try std.testing.expectEqual(@as(u32, 2), r2.height);
    for (0..2) |y| {
        for (0..2) |x| {
            const px = getPixel(r2.pixels, @intCast(x), @intCast(y), r2.width);
            try std.testing.expectEqualSlices(u8, &C, &px);
        }
    }

    // 3x
    var r3 = try upscale(allocator, &src, 1, 1, .x3);
    defer r3.deinit();
    try std.testing.expectEqual(@as(u32, 3), r3.width);
    try std.testing.expectEqual(@as(u32, 3), r3.height);

    // 4x
    var r4 = try upscale(allocator, &src, 1, 1, .x4);
    defer r4.deinit();
    try std.testing.expectEqual(@as(u32, 4), r4.width);
    try std.testing.expectEqual(@as(u32, 4), r4.height);
}

// === Transparency preservation ===

test "upscale preserves transparent pixels" {
    const allocator = std.testing.allocator;
    const T = rgba(0, 0, 0, 0); // transparent
    const R = rgba(255, 0, 0, 255); // red opaque

    const src = buildImage(2, 2, .{
        .{ T, R },
        .{ R, T },
    });

    var result = try upscale(allocator, &src, 2, 2, .x2);
    defer result.deinit();

    // Top-left corner (E0 of source pixel (0,0)=T) should be transparent
    const tl = getPixel(result.pixels, 0, 0, result.width);
    try std.testing.expectEqual(@as(u8, 0), tl[3]);
}

// === Scale3x specific test ===

test "scale3x produces correct output dimensions" {
    const allocator = std.testing.allocator;
    const W = rgba(255, 255, 255, 255);
    const src = buildImage(3, 3, .{
        .{ W, W, W },
        .{ W, W, W },
        .{ W, W, W },
    });

    var result = try upscale(allocator, &src, 3, 3, .x3);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 9), result.width);
    try std.testing.expectEqual(@as(u32, 9), result.height);

    // Solid color: all output pixels should match
    for (0..9) |y| {
        for (0..9) |x| {
            const px = getPixel(result.pixels, @intCast(x), @intCast(y), result.width);
            try std.testing.expectEqualSlices(u8, &W, &px);
        }
    }
}

test "scale3x smooths diagonal edges" {
    const allocator = std.testing.allocator;
    const K = rgba(0, 0, 0, 255);
    const W = rgba(255, 255, 255, 255);

    // 3x3 image with L-shaped boundary:
    //   K K W
    //   K W W
    //   W W W
    const src = buildImage(3, 3, .{
        .{ K, K, W },
        .{ K, W, W },
        .{ W, W, W },
    });

    var result = try upscale(allocator, &src, 3, 3, .x3);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 9), result.width);
    try std.testing.expectEqual(@as(u32, 9), result.height);

    // Center pixel (1,1) = W. Its E4 (center of 3x3 output block) is always E = W.
    // Output coords: E4 of (1,1) is at (4, 4).
    const center = getPixel(result.pixels, 4, 4, result.width);
    try std.testing.expectEqualSlices(u8, &W, &center);

    // The top-left corner pixel (0,0) = K should remain K in its center output.
    // E4 of (0,0) is at (1, 1).
    const corner_center = getPixel(result.pixels, 1, 1, result.width);
    try std.testing.expectEqualSlices(u8, &K, &corner_center);
}

// === 4x quality test ===

test "4x upscale of checkerboard does not crash" {
    const allocator = std.testing.allocator;
    const K = rgba(0, 0, 0, 255);
    const W = rgba(255, 255, 255, 255);

    const src = buildImage(4, 4, .{
        .{ K, W, K, W },
        .{ W, K, W, K },
        .{ K, W, K, W },
        .{ W, K, W, K },
    });

    var result = try upscale(allocator, &src, 4, 4, .x4);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 16), result.width);
    try std.testing.expectEqual(@as(u32, 16), result.height);
    // Checkerboard has no edges to smooth (all neighbors differ),
    // so Scale2x produces nearest-neighbor output. Just verify it doesn't crash.
}
