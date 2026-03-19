//! Sprite rendering pipeline for visual verification.
//! Converts palette-indexed sprites to RGBA images and encodes as PNG.

const std = @import("std");
const sprite_mod = @import("../formats/sprite.zig");
const pal_mod = @import("../formats/pal.zig");
const iff_mod = @import("../formats/iff.zig");
const png_mod = @import("png.zig");
const scene_renderer = @import("scene_renderer.zig");

/// An RGBA image ready for PNG encoding.
pub const RgbaImage = struct {
    width: u32,
    height: u32,
    /// RGBA pixel data (4 bytes per pixel, row-major).
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RgbaImage) void {
        self.allocator.free(self.pixels);
    }
};

/// Convert a decoded sprite (palette indices) to RGBA using the given palette.
/// Index 0 is treated as fully transparent.
pub fn spriteToRgba(allocator: std.mem.Allocator, spr: sprite_mod.Sprite, palette: pal_mod.Palette) !RgbaImage {
    const pixel_count = @as(usize, spr.width) * @as(usize, spr.height);
    const rgba = try allocator.alloc(u8, pixel_count * 4);
    errdefer allocator.free(rgba);

    for (0..pixel_count) |i| {
        const idx = spr.pixels[i];
        const offset = i * 4;
        if (idx == 0) {
            rgba[offset] = 0;
            rgba[offset + 1] = 0;
            rgba[offset + 2] = 0;
            rgba[offset + 3] = 0;
        } else {
            const color = palette.colors[idx];
            rgba[offset] = color.r;
            rgba[offset + 1] = color.g;
            rgba[offset + 2] = color.b;
            rgba[offset + 3] = 255;
        }
    }

    return .{
        .width = spr.width,
        .height = spr.height,
        .pixels = rgba,
        .allocator = allocator,
    };
}

/// Render a sprite to PNG bytes using the given palette.
pub fn spriteToPng(allocator: std.mem.Allocator, spr: sprite_mod.Sprite, palette: pal_mod.Palette) ![]u8 {
    var image = try spriteToRgba(allocator, spr, palette);
    defer image.deinit();
    return png_mod.encode(allocator, image.width, image.height, image.pixels);
}

/// Recursively find and decode all SHAP chunks from an IFF chunk tree.
/// Returns a list of decoded sprites (caller owns; deinit each, then free slice).
pub fn findSprites(allocator: std.mem.Allocator, chunk: iff_mod.Chunk) ![]sprite_mod.Sprite {
    var sprites: std.ArrayListUnmanaged(sprite_mod.Sprite) = .empty;
    errdefer {
        for (sprites.items) |*s| s.deinit();
        sprites.deinit(allocator);
    }

    findSpritesRecursive(allocator, chunk, &sprites);
    return sprites.toOwnedSlice(allocator);
}

fn findSpritesRecursive(allocator: std.mem.Allocator, chunk: iff_mod.Chunk, sprites: *std.ArrayListUnmanaged(sprite_mod.Sprite)) void {
    if (std.mem.eql(u8, &chunk.tag, "SHAP") and !chunk.isContainer()) {
        if (chunk.data.len >= 8) {
            // SHAP chunks typically contain a scene pack: 4-byte size + offset table + sprites.
            // Try scene pack first, fall back to raw RLE.
            if (decodeScenePackSprites(allocator, chunk.data)) |pack_sprites| {
                for (pack_sprites) |s| {
                    sprites.append(allocator, s) catch {
                        var sp = s;
                        sp.deinit();
                        continue;
                    };
                }
                allocator.free(pack_sprites);
                return;
            }
        }
        // Fallback: try raw RLE decode (some SHAP chunks may be bare sprites)
        if (chunk.data.len >= sprite_mod.HEADER_SIZE) {
            var s = sprite_mod.decode(allocator, chunk.data) catch return;
            // Sanity check dimensions
            if (s.width > 0 and s.height > 0 and s.width <= 640 and s.height <= 480) {
                sprites.append(allocator, s) catch {
                    s.deinit();
                    return;
                };
            } else {
                s.deinit();
            }
        }
    }

    for (chunk.children) |child| {
        findSpritesRecursive(allocator, child, sprites);
    }
}

/// Decode all sprites from a scene pack (offset table + sprite data).
fn decodeScenePackSprites(allocator: std.mem.Allocator, data: []const u8) ?[]sprite_mod.Sprite {
    var pack = scene_renderer.parseScenePack(allocator, data) catch return null;
    defer pack.deinit();

    var result: std.ArrayListUnmanaged(sprite_mod.Sprite) = .empty;
    errdefer {
        for (result.items) |*s| s.deinit();
        result.deinit(allocator);
    }

    for (pack.sprite_offsets) |offset| {
        if (offset + sprite_mod.HEADER_SIZE > data.len) continue;
        var s = sprite_mod.decode(allocator, data[offset..]) catch continue;
        // Sanity check dimensions
        if (s.width > 0 and s.height > 0 and s.width <= 640 and s.height <= 480) {
            result.append(allocator, s) catch {
                s.deinit();
                continue;
            };
        } else {
            s.deinit();
        }
    }

    if (result.items.len == 0) {
        result.deinit(allocator);
        return null;
    }
    return result.toOwnedSlice(allocator) catch null;
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "spriteToRgba converts transparent index 0 to alpha 0" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_sprite_offset.bin");
    defer allocator.free(data);

    var spr = try sprite_mod.decode(allocator, data);
    defer spr.deinit();

    // Sprite pixels: Row 0: [0, 15, 16, 17, 0, 0], Row 1: [0, 0, 20, 21, 0, 0]
    var palette: pal_mod.Palette = undefined;
    palette.header = .{ 0, 0, 0, 0 };
    for (0..256) |i| {
        palette.colors[i] = .{
            .r = @intCast(i),
            .g = @intCast(i),
            .b = @intCast(i),
        };
    }

    var image = try spriteToRgba(allocator, spr, palette);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 6), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);

    // First pixel (index 0): fully transparent
    try std.testing.expectEqual(@as(u8, 0), image.pixels[0]); // r
    try std.testing.expectEqual(@as(u8, 0), image.pixels[1]); // g
    try std.testing.expectEqual(@as(u8, 0), image.pixels[2]); // b
    try std.testing.expectEqual(@as(u8, 0), image.pixels[3]); // a

    // Second pixel (index 15): opaque with palette color
    try std.testing.expectEqual(@as(u8, 15), image.pixels[4]); // r
    try std.testing.expectEqual(@as(u8, 15), image.pixels[5]); // g
    try std.testing.expectEqual(@as(u8, 15), image.pixels[6]); // b
    try std.testing.expectEqual(@as(u8, 255), image.pixels[7]); // a
}

test "spriteToRgba preserves dimensions" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_sprite_even.bin");
    defer allocator.free(data);

    var spr = try sprite_mod.decode(allocator, data);
    defer spr.deinit();

    var palette: pal_mod.Palette = undefined;
    palette.header = .{ 0, 0, 0, 0 };
    for (0..256) |i| {
        palette.colors[i] = .{ .r = @intCast(i), .g = @intCast(i), .b = @intCast(i) };
    }

    var image = try spriteToRgba(allocator, spr, palette);
    defer image.deinit();

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(usize, 64), image.pixels.len); // 4*4*4 RGBA
}

test "spriteToRgba maps palette colors correctly" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_sprite_even.bin");
    defer allocator.free(data);

    var spr = try sprite_mod.decode(allocator, data);
    defer spr.deinit();

    // Set distinct RGB values for each palette index
    var palette: pal_mod.Palette = undefined;
    palette.header = .{ 0, 0, 0, 0 };
    for (0..256) |i| {
        const v: u8 = @intCast(i);
        palette.colors[i] = .{ .r = v, .g = 255 -% v, .b = v *% 2 };
    }

    var image = try spriteToRgba(allocator, spr, palette);
    defer image.deinit();

    // First pixel has palette index 1
    try std.testing.expectEqual(@as(u8, 1), image.pixels[0]); // r = 1
    try std.testing.expectEqual(@as(u8, 254), image.pixels[1]); // g = 255-1
    try std.testing.expectEqual(@as(u8, 2), image.pixels[2]); // b = 1*2
    try std.testing.expectEqual(@as(u8, 255), image.pixels[3]); // a = opaque
}

test "spriteToPng produces valid PNG with correct signature" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_sprite_even.bin");
    defer allocator.free(data);

    var spr = try sprite_mod.decode(allocator, data);
    defer spr.deinit();

    var palette: pal_mod.Palette = undefined;
    palette.header = .{ 0, 0, 0, 0 };
    for (0..256) |i| {
        palette.colors[i] = .{ .r = @intCast(i), .g = @intCast(i), .b = @intCast(i) };
    }

    const png_data = try spriteToPng(allocator, spr, palette);
    defer allocator.free(png_data);

    // Must start with PNG signature
    try std.testing.expectEqualSlices(u8, &png_mod.SIGNATURE, png_data[0..8]);
    // Must contain IHDR chunk
    try std.testing.expectEqualSlices(u8, "IHDR", png_data[12..16]);
    // Must be non-trivial size
    try std.testing.expect(png_data.len > 50);
}

test "spriteToPng encodes correct dimensions in IHDR" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_sprite_offset.bin");
    defer allocator.free(data);

    var spr = try sprite_mod.decode(allocator, data);
    defer spr.deinit();

    var palette: pal_mod.Palette = undefined;
    palette.header = .{ 0, 0, 0, 0 };
    for (0..256) |i| {
        palette.colors[i] = .{ .r = @intCast(i), .g = @intCast(i), .b = @intCast(i) };
    }

    const png_data = try spriteToPng(allocator, spr, palette);
    defer allocator.free(png_data);

    // IHDR data starts at offset 16 (8 sig + 4 len + 4 type)
    const w = std.mem.readInt(u32, png_data[16..20], .big);
    const h = std.mem.readInt(u32, png_data[20..24], .big);
    try std.testing.expectEqual(@as(u32, 6), w);
    try std.testing.expectEqual(@as(u32, 2), h);
}
