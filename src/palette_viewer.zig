//! Palette viewer: renders 256-color palettes as color swatch grid PNGs.
//! Each palette is rendered as a 16x16 grid of color swatches for visual verification.

const std = @import("std");
const pal_mod = @import("pal.zig");
const png_mod = @import("png.zig");
const render_mod = @import("render.zig");

/// Size of each color swatch in pixels.
pub const SWATCH_SIZE: u32 = 16;

/// Number of columns in the grid (16 colors per row).
pub const GRID_COLS: u32 = 16;

/// Number of rows in the grid (16 rows for 256 colors).
pub const GRID_ROWS: u32 = 16;

/// Total image width in pixels.
pub const IMAGE_WIDTH: u32 = GRID_COLS * SWATCH_SIZE; // 256

/// Total image height in pixels.
pub const IMAGE_HEIGHT: u32 = GRID_ROWS * SWATCH_SIZE; // 256

/// Render a palette as a 16x16 grid of color swatches (RGBA image).
/// Each swatch is SWATCH_SIZE x SWATCH_SIZE pixels. All 256 colors are shown,
/// arranged left-to-right, top-to-bottom (index 0 at top-left, 255 at bottom-right).
pub fn renderPaletteGrid(allocator: std.mem.Allocator, palette: pal_mod.Palette) !render_mod.RgbaImage {
    const pixel_count = @as(usize, IMAGE_WIDTH) * @as(usize, IMAGE_HEIGHT);
    const rgba = try allocator.alloc(u8, pixel_count * 4);
    errdefer allocator.free(rgba);

    for (0..@as(usize, IMAGE_HEIGHT)) |y| {
        const grid_row = y / SWATCH_SIZE;
        for (0..@as(usize, IMAGE_WIDTH)) |x| {
            const grid_col = x / SWATCH_SIZE;
            const color_idx = grid_row * GRID_COLS + grid_col;
            const color = palette.colors[color_idx];
            const offset = (y * IMAGE_WIDTH + x) * 4;
            rgba[offset] = color.r;
            rgba[offset + 1] = color.g;
            rgba[offset + 2] = color.b;
            rgba[offset + 3] = 255; // fully opaque
        }
    }

    return .{
        .width = IMAGE_WIDTH,
        .height = IMAGE_HEIGHT,
        .pixels = rgba,
        .allocator = allocator,
    };
}

/// Render a palette to PNG bytes.
pub fn paletteToPng(allocator: std.mem.Allocator, palette: pal_mod.Palette) ![]u8 {
    var image = try renderPaletteGrid(allocator, palette);
    defer image.deinit();
    return png_mod.encode(allocator, image.width, image.height, image.pixels);
}

// --- Tests ---

fn makeTestPalette() pal_mod.Palette {
    var palette: pal_mod.Palette = undefined;
    palette.header = .{ 0, 0, 0, 0 };
    for (0..256) |i| {
        palette.colors[i] = .{
            .r = @intCast(i),
            .g = @intCast(255 - i),
            .b = @intCast((i *% 37) & 0xFF),
        };
    }
    return palette;
}

test "renderPaletteGrid produces 256x256 image" {
    const allocator = std.testing.allocator;
    const palette = makeTestPalette();

    var image = try renderPaletteGrid(allocator, palette);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 256), image.width);
    try std.testing.expectEqual(@as(u32, 256), image.height);
    try std.testing.expectEqual(@as(usize, 256 * 256 * 4), image.pixels.len);
}

test "renderPaletteGrid top-left pixel is color 0" {
    const allocator = std.testing.allocator;
    var palette: pal_mod.Palette = undefined;
    palette.header = .{ 0, 0, 0, 0 };
    palette.colors[0] = .{ .r = 10, .g = 20, .b = 30 };
    for (1..256) |i| {
        palette.colors[i] = .{ .r = 0, .g = 0, .b = 0 };
    }

    var image = try renderPaletteGrid(allocator, palette);
    defer image.deinit();

    // Pixel (0,0) should be color index 0
    try std.testing.expectEqual(@as(u8, 10), image.pixels[0]);
    try std.testing.expectEqual(@as(u8, 20), image.pixels[1]);
    try std.testing.expectEqual(@as(u8, 30), image.pixels[2]);
    try std.testing.expectEqual(@as(u8, 255), image.pixels[3]);
}

test "renderPaletteGrid color 1 starts at pixel column 16" {
    const allocator = std.testing.allocator;
    var palette: pal_mod.Palette = undefined;
    palette.header = .{ 0, 0, 0, 0 };
    for (0..256) |i| {
        palette.colors[i] = .{ .r = 0, .g = 0, .b = 0 };
    }
    palette.colors[1] = .{ .r = 100, .g = 150, .b = 200 };

    var image = try renderPaletteGrid(allocator, palette);
    defer image.deinit();

    // Color 1 swatch starts at pixel (16, 0)
    const offset = (0 * IMAGE_WIDTH + 16) * 4;
    try std.testing.expectEqual(@as(u8, 100), image.pixels[offset]);
    try std.testing.expectEqual(@as(u8, 150), image.pixels[offset + 1]);
    try std.testing.expectEqual(@as(u8, 200), image.pixels[offset + 2]);
    try std.testing.expectEqual(@as(u8, 255), image.pixels[offset + 3]);
}

test "renderPaletteGrid color 16 starts at row 1" {
    const allocator = std.testing.allocator;
    var palette: pal_mod.Palette = undefined;
    palette.header = .{ 0, 0, 0, 0 };
    for (0..256) |i| {
        palette.colors[i] = .{ .r = 0, .g = 0, .b = 0 };
    }
    palette.colors[16] = .{ .r = 50, .g = 60, .b = 70 };

    var image = try renderPaletteGrid(allocator, palette);
    defer image.deinit();

    // Color 16 is at grid position (col=0, row=1), pixel (0, 16)
    const offset = (16 * IMAGE_WIDTH + 0) * 4;
    try std.testing.expectEqual(@as(u8, 50), image.pixels[offset]);
    try std.testing.expectEqual(@as(u8, 60), image.pixels[offset + 1]);
    try std.testing.expectEqual(@as(u8, 70), image.pixels[offset + 2]);
}

test "renderPaletteGrid color 255 at bottom-right" {
    const allocator = std.testing.allocator;
    var palette: pal_mod.Palette = undefined;
    palette.header = .{ 0, 0, 0, 0 };
    for (0..256) |i| {
        palette.colors[i] = .{ .r = 0, .g = 0, .b = 0 };
    }
    palette.colors[255] = .{ .r = 255, .g = 128, .b = 64 };

    var image = try renderPaletteGrid(allocator, palette);
    defer image.deinit();

    // Color 255 is at grid position (col=15, row=15), pixel (240, 240)
    const offset = (240 * IMAGE_WIDTH + 240) * 4;
    try std.testing.expectEqual(@as(u8, 255), image.pixels[offset]);
    try std.testing.expectEqual(@as(u8, 128), image.pixels[offset + 1]);
    try std.testing.expectEqual(@as(u8, 64), image.pixels[offset + 2]);
}

test "renderPaletteGrid swatch fills 16x16 area with same color" {
    const allocator = std.testing.allocator;
    var palette: pal_mod.Palette = undefined;
    palette.header = .{ 0, 0, 0, 0 };
    for (0..256) |i| {
        palette.colors[i] = .{ .r = @intCast(i), .g = @intCast(i), .b = @intCast(i) };
    }

    var image = try renderPaletteGrid(allocator, palette);
    defer image.deinit();

    // Check that all 16x16 pixels in the swatch for color 5 (col=5, row=0) are the same
    for (0..SWATCH_SIZE) |dy| {
        for (0..SWATCH_SIZE) |dx| {
            const px = 5 * SWATCH_SIZE + dx;
            const py = 0 * SWATCH_SIZE + dy;
            const offset = (py * IMAGE_WIDTH + px) * 4;
            try std.testing.expectEqual(@as(u8, 5), image.pixels[offset]);
            try std.testing.expectEqual(@as(u8, 5), image.pixels[offset + 1]);
            try std.testing.expectEqual(@as(u8, 5), image.pixels[offset + 2]);
            try std.testing.expectEqual(@as(u8, 255), image.pixels[offset + 3]);
        }
    }
}

test "paletteToPng produces valid PNG with correct signature" {
    const allocator = std.testing.allocator;
    const palette = makeTestPalette();

    const png_data = try paletteToPng(allocator, palette);
    defer allocator.free(png_data);

    // Must start with PNG signature
    try std.testing.expectEqualSlices(u8, &png_mod.SIGNATURE, png_data[0..8]);
    // Must contain IHDR chunk
    try std.testing.expectEqualSlices(u8, "IHDR", png_data[12..16]);
}

test "paletteToPng encodes 256x256 dimensions in IHDR" {
    const allocator = std.testing.allocator;
    const palette = makeTestPalette();

    const png_data = try paletteToPng(allocator, palette);
    defer allocator.free(png_data);

    // IHDR data starts at offset 16 (8 sig + 4 len + 4 type)
    const w = std.mem.readInt(u32, png_data[16..20], .big);
    const h = std.mem.readInt(u32, png_data[20..24], .big);
    try std.testing.expectEqual(@as(u32, 256), w);
    try std.testing.expectEqual(@as(u32, 256), h);
}

test "paletteToPng produces non-trivial output" {
    const allocator = std.testing.allocator;
    const palette = makeTestPalette();

    const png_data = try paletteToPng(allocator, palette);
    defer allocator.free(png_data);

    // A 256x256 RGBA image should produce substantial PNG data
    try std.testing.expect(png_data.len > 1000);
}
