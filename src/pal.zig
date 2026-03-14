//! PAL (Palette) file parser for Wing Commander: Privateer.
//! Parses VGA palette files: 4-byte header + 768 bytes of 6-bit RGB data (256 colors).
//! Converts VGA 6-bit color values (0-63) to standard 8-bit (0-255).

const std = @import("std");

pub const HEADER_SIZE: usize = 4;
pub const COLOR_COUNT: usize = 256;
pub const RGB_DATA_SIZE: usize = COLOR_COUNT * 3; // 768 bytes
pub const PAL_FILE_SIZE: usize = HEADER_SIZE + RGB_DATA_SIZE; // 772 bytes

/// A single RGB color with 8-bit channels (0-255).
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// A parsed 256-color palette.
pub const Palette = struct {
    /// The 4-byte header/flags from the file.
    header: [4]u8,
    /// 256 RGB colors, converted from VGA 6-bit to 8-bit.
    colors: [COLOR_COUNT]Color,
};

pub const PalError = error{
    InvalidSize,
    InvalidColorValue,
};

/// Convert a VGA 6-bit color component (0-63) to 8-bit (0-255).
/// Uses the standard VGA conversion: multiply by 4 (and OR with the top 2 bits
/// shifted down to fill the low bits for a more accurate mapping).
pub fn vga6to8(value: u8) PalError!u8 {
    if (value > 63) return PalError.InvalidColorValue;
    // Standard conversion: (value << 2) | (value >> 4)
    // This maps 0->0, 63->255 exactly, with smooth interpolation
    return (value << 2) | (value >> 4);
}

/// Parse a PAL file from raw bytes.
/// Expects exactly 772 bytes (4-byte header + 768 bytes RGB data).
pub fn parse(data: []const u8) PalError!Palette {
    if (data.len < PAL_FILE_SIZE) return PalError.InvalidSize;

    var palette: Palette = undefined;
    palette.header = data[0..4].*;

    // Parse 256 RGB entries, converting from 6-bit to 8-bit
    for (0..COLOR_COUNT) |i| {
        const offset = HEADER_SIZE + i * 3;
        palette.colors[i] = .{
            .r = try vga6to8(data[offset]),
            .g = try vga6to8(data[offset + 1]),
            .b = try vga6to8(data[offset + 2]),
        };
    }

    return palette;
}

// --- Tests ---

const testing_helpers = @import("testing.zig");

test "parse loads 256 RGB entries from test_pal.bin" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_pal.bin");
    defer allocator.free(data);

    const palette = try parse(data);
    // First entry should be black (0,0,0)
    try std.testing.expectEqual(@as(u8, 0), palette.colors[0].r);
    try std.testing.expectEqual(@as(u8, 0), palette.colors[0].g);
    try std.testing.expectEqual(@as(u8, 0), palette.colors[0].b);
}

test "parse reads header bytes" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_pal.bin");
    defer allocator.free(data);

    const palette = try parse(data);
    // test_pal.bin header is 0x00, 0x01, 0x00, 0x00
    try std.testing.expectEqual(@as(u8, 0x00), palette.header[0]);
    try std.testing.expectEqual(@as(u8, 0x01), palette.header[1]);
    try std.testing.expectEqual(@as(u8, 0x00), palette.header[2]);
    try std.testing.expectEqual(@as(u8, 0x00), palette.header[3]);
}

test "VGA 6-bit to 8-bit conversion" {
    // 0 -> 0
    try std.testing.expectEqual(@as(u8, 0), try vga6to8(0));
    // 63 -> 255
    try std.testing.expectEqual(@as(u8, 255), try vga6to8(63));
    // 32 -> (32 << 2) | (32 >> 4) = 128 | 2 = 130
    try std.testing.expectEqual(@as(u8, 130), try vga6to8(32));
    // 16 -> (16 << 2) | (16 >> 4) = 64 | 1 = 65
    try std.testing.expectEqual(@as(u8, 65), try vga6to8(16));
    // 64 is invalid (> 63)
    try std.testing.expectError(PalError.InvalidColorValue, vga6to8(64));
}

test "parse converts VGA 6-bit values to 8-bit correctly" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_pal.bin");
    defer allocator.free(data);

    const palette = try parse(data);

    // Entry 1 has VGA values (63, 0, 0) -> 8-bit (255, 0, 0) = bright red
    try std.testing.expectEqual(@as(u8, 255), palette.colors[1].r);
    try std.testing.expectEqual(@as(u8, 0), palette.colors[1].g);
    try std.testing.expectEqual(@as(u8, 0), palette.colors[1].b);

    // Entry 2 has VGA values (0, 63, 0) -> 8-bit (0, 255, 0) = bright green
    try std.testing.expectEqual(@as(u8, 0), palette.colors[2].r);
    try std.testing.expectEqual(@as(u8, 255), palette.colors[2].g);
    try std.testing.expectEqual(@as(u8, 0), palette.colors[2].b);

    // Entry 3 has VGA values (0, 0, 63) -> 8-bit (0, 0, 255) = bright blue
    try std.testing.expectEqual(@as(u8, 0), palette.colors[3].r);
    try std.testing.expectEqual(@as(u8, 0), palette.colors[3].g);
    try std.testing.expectEqual(@as(u8, 255), palette.colors[3].b);

    // Entry 4 has VGA values (32, 32, 32) -> 8-bit (130, 130, 130) = medium gray
    try std.testing.expectEqual(@as(u8, 130), palette.colors[4].r);
    try std.testing.expectEqual(@as(u8, 130), palette.colors[4].g);
    try std.testing.expectEqual(@as(u8, 130), palette.colors[4].b);

    // Entry 255 has VGA values (63, 63, 63) -> 8-bit (255, 255, 255) = white
    try std.testing.expectEqual(@as(u8, 255), palette.colors[255].r);
    try std.testing.expectEqual(@as(u8, 255), palette.colors[255].g);
    try std.testing.expectEqual(@as(u8, 255), palette.colors[255].b);
}

test "parse rejects too-small data" {
    const data = [_]u8{0} ** 100; // way too small
    try std.testing.expectError(PalError.InvalidSize, parse(&data));
}

test "parse rejects data with invalid VGA values" {
    // Build a 772-byte PAL with an invalid color value (> 63)
    var data = [_]u8{0} ** PAL_FILE_SIZE;
    data[4] = 99; // invalid: > 63
    try std.testing.expectError(PalError.InvalidColorValue, parse(&data));
}
