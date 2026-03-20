//! RLE sprite decoder for Wing Commander: Privateer.
//! Parses Origin's proprietary Run-Length Encoded sprite format used for all
//! sprite graphics. Sprites have an 8-byte header defining center-relative
//! extents, followed by RLE-encoded pixel data (palette indices).

const std = @import("std");

pub const HEADER_SIZE: usize = 8;

/// Sprite header defining the image extents relative to center.
pub const SpriteHeader = struct {
    /// Pixels right of center.
    x2: i16,
    /// Pixels left of center.
    x1: i16,
    /// Pixels above center.
    y1: i16,
    /// Pixels below center.
    y2: i16,

    /// Sprite width: x1 + 1 + x2 (left extent + center pixel + right extent).
    pub fn width(self: SpriteHeader) SpriteError!u16 {
        const w = @as(i32, self.x1) + @as(i32, self.x2) + 1;
        if (w <= 0) return SpriteError.InvalidDimensions;
        return @intCast(w);
    }

    /// Sprite height: y1 + 1 + y2 (top extent + center pixel + bottom extent).
    pub fn height(self: SpriteHeader) SpriteError!u16 {
        const h = @as(i32, self.y1) + @as(i32, self.y2) + 1;
        if (h <= 0) return SpriteError.InvalidDimensions;
        return @intCast(h);
    }
};

/// A decoded sprite with pixel data (palette indices).
pub const Sprite = struct {
    header: SpriteHeader,
    /// Width in pixels.
    width: u16,
    /// Height in pixels.
    height: u16,
    /// Row-major pixel data (palette indices). Length = width * height.
    /// Index 0 = transparent.
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Sprite) void {
        self.allocator.free(self.pixels);
    }
};

pub const SpriteError = error{
    UnexpectedEnd,
    InvalidHeader,
    InvalidDimensions,
    PixelOutOfBounds,
    OutOfMemory,
};

/// Parse the 8-byte sprite header from raw data.
pub fn parseHeader(data: []const u8) SpriteError!SpriteHeader {
    if (data.len < HEADER_SIZE) return SpriteError.UnexpectedEnd;

    const x2 = std.mem.readInt(i16, data[0..2], .little);
    const x1 = std.mem.readInt(i16, data[2..4], .little);
    const y1 = std.mem.readInt(i16, data[4..6], .little);
    const y2 = std.mem.readInt(i16, data[6..8], .little);

    return .{ .x2 = x2, .x1 = x1, .y1 = y1, .y2 = y2 };
}

/// Decode an RLE-encoded sprite from raw bytes.
/// The data should start with the 8-byte header followed by RLE data.
/// Returns a Sprite with allocated pixel buffer (caller owns via deinit).
pub fn decode(allocator: std.mem.Allocator, data: []const u8) SpriteError!Sprite {
    const header = try parseHeader(data);

    const w = try header.width();
    const h = try header.height();

    const pixel_count: usize = @as(usize, w) * @as(usize, h);
    const pixels = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(pixels);
    @memset(pixels, 0); // transparent by default

    // Decode RLE data starting after the header
    var offset: usize = HEADER_SIZE;
    while (offset + 1 < data.len) {
        const key = readU16LE(data, offset) catch break;
        offset += 2;

        // Key of 0 terminates the sprite data
        if (key == 0) break;

        const x_off = readU16LE(data, offset) catch return SpriteError.UnexpectedEnd;
        offset += 2;
        const y_off = readU16LE(data, offset) catch return SpriteError.UnexpectedEnd;
        offset += 2;

        const pixel_num: usize = key / 2;

        if (key & 1 == 0) {
            // Even key: raw pixel run
            offset = try decodeEvenKey(data, offset, pixels, x_off, y_off, pixel_num, w, h);
        } else {
            // Odd key: sub-encoded data
            offset = try decodeOddKey(data, offset, pixels, x_off, y_off, pixel_num, w, h);
        }
    }

    return .{
        .header = header,
        .width = w,
        .height = h,
        .pixels = pixels,
        .allocator = allocator,
    };
}

/// Decode even-key segment: pixel_count raw color bytes.
fn decodeEvenKey(
    data: []const u8,
    start_offset: usize,
    pixels: []u8,
    x_off: u16,
    y_off: u16,
    pixel_count: usize,
    width: u16,
    height: u16,
) SpriteError!usize {
    var offset = start_offset;
    for (0..pixel_count) |i| {
        if (offset >= data.len) return SpriteError.UnexpectedEnd;
        const color = data[offset];
        offset += 1;

        const px: usize = @as(usize, x_off) + i;
        const py: usize = @as(usize, y_off);
        if (px < width and py < height) {
            pixels[py * @as(usize, width) + px] = color;
        }
    }
    return offset;
}

/// Decode odd-key segment: sub-encoded data with literal and repeat runs.
fn decodeOddKey(
    data: []const u8,
    start_offset: usize,
    pixels: []u8,
    x_off: u16,
    y_off: u16,
    total_pixels: usize,
    width: u16,
    height: u16,
) SpriteError!usize {
    var offset = start_offset;
    var pixels_written: usize = 0;

    while (pixels_written < total_pixels) {
        if (offset >= data.len) return SpriteError.UnexpectedEnd;
        const sub_byte = data[offset];
        offset += 1;

        const sub_count: usize = sub_byte / 2;

        if (sub_byte & 1 == 0) {
            // Even sub-byte: literal colors follow
            for (0..sub_count) |_| {
                if (offset >= data.len) return SpriteError.UnexpectedEnd;
                const color = data[offset];
                offset += 1;

                const px = @as(usize, x_off) + pixels_written;
                const py = @as(usize, y_off);
                if (px < width and py < height) {
                    pixels[py * @as(usize, width) + px] = color;
                }
                pixels_written += 1;
            }
        } else {
            // Odd sub-byte: repeat single color
            if (offset >= data.len) return SpriteError.UnexpectedEnd;
            const color = data[offset];
            offset += 1;

            for (0..sub_count) |_| {
                const px = @as(usize, x_off) + pixels_written;
                const py = @as(usize, y_off);
                if (px < width and py < height) {
                    pixels[py * @as(usize, width) + px] = color;
                }
                pixels_written += 1;
            }
        }
    }
    return offset;
}

fn readU16LE(data: []const u8, offset: usize) SpriteError!u16 {
    if (offset + 2 > data.len) return SpriteError.UnexpectedEnd;
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "parseHeader reads 8-byte sprite header" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_sprite_even.bin");
    defer allocator.free(data);

    const header = try parseHeader(data);
    try std.testing.expectEqual(@as(i16, 3), header.x2);
    try std.testing.expectEqual(@as(i16, 0), header.x1);
    try std.testing.expectEqual(@as(i16, 0), header.y1);
    try std.testing.expectEqual(@as(i16, 3), header.y2);
    try std.testing.expectEqual(@as(u16, 4), try header.width());
    try std.testing.expectEqual(@as(u16, 4), try header.height());
}

test "parseHeader rejects too-small data" {
    const data = [_]u8{0} ** 4; // only 4 bytes, need 8
    try std.testing.expectError(SpriteError.UnexpectedEnd, parseHeader(&data));
}

test "decode even-key RLE produces correct raw pixel runs" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_sprite_even.bin");
    defer allocator.free(data);

    var sprite = try decode(allocator, data);
    defer sprite.deinit();

    try std.testing.expectEqual(@as(u16, 4), sprite.width);
    try std.testing.expectEqual(@as(u16, 4), sprite.height);

    // Row 0: [1, 2, 3, 4]
    try testing_helpers.expectBytes(&[_]u8{ 1, 2, 3, 4 }, sprite.pixels[0..4]);
    // Row 1: [5, 6, 7, 8]
    try testing_helpers.expectBytes(&[_]u8{ 5, 6, 7, 8 }, sprite.pixels[4..8]);
    // Row 2: [9, 10, 11, 12]
    try testing_helpers.expectBytes(&[_]u8{ 9, 10, 11, 12 }, sprite.pixels[8..12]);
    // Row 3: [13, 14, 15, 16]
    try testing_helpers.expectBytes(&[_]u8{ 13, 14, 15, 16 }, sprite.pixels[12..16]);
}

test "decode odd-key RLE with repeat sub-byte" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_sprite_odd.bin");
    defer allocator.free(data);

    var sprite = try decode(allocator, data);
    defer sprite.deinit();

    try std.testing.expectEqual(@as(u16, 4), sprite.width);
    try std.testing.expectEqual(@as(u16, 4), sprite.height);

    // Row 0: odd key, repeat sub-byte => [5, 5, 5, 5]
    try testing_helpers.expectBytes(&[_]u8{ 5, 5, 5, 5 }, sprite.pixels[0..4]);
    // Row 1: odd key, literal sub-byte => [10, 11, 12, 13]
    try testing_helpers.expectBytes(&[_]u8{ 10, 11, 12, 13 }, sprite.pixels[4..8]);
    // Row 2: odd key, mixed (2 literal + 2 repeat) => [30, 31, 40, 40]
    try testing_helpers.expectBytes(&[_]u8{ 30, 31, 40, 40 }, sprite.pixels[8..12]);
    // Row 3: odd key, repeat sub-byte => [20, 20, 20, 20]
    try testing_helpers.expectBytes(&[_]u8{ 20, 20, 20, 20 }, sprite.pixels[12..16]);
}

test "decode handles non-zero X offsets (sparse sprite)" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_sprite_offset.bin");
    defer allocator.free(data);

    var sprite = try decode(allocator, data);
    defer sprite.deinit();

    try std.testing.expectEqual(@as(u16, 6), sprite.width);
    try std.testing.expectEqual(@as(u16, 2), sprite.height);

    // Row 0: [0, 15, 16, 17, 0, 0]
    try testing_helpers.expectBytes(&[_]u8{ 0, 15, 16, 17, 0, 0 }, sprite.pixels[0..6]);
    // Row 1: [0, 0, 20, 21, 0, 0]
    try testing_helpers.expectBytes(&[_]u8{ 0, 0, 20, 21, 0, 0 }, sprite.pixels[6..12]);
}

test "decode produces correct dimensions from header" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_sprite_offset.bin");
    defer allocator.free(data);

    var sprite = try decode(allocator, data);
    defer sprite.deinit();

    // Header: X2=5, X1=0, Y1=0, Y2=1 => 6x2
    try std.testing.expectEqual(@as(i16, 5), sprite.header.x2);
    try std.testing.expectEqual(@as(i16, 0), sprite.header.x1);
    try std.testing.expectEqual(@as(i16, 0), sprite.header.y1);
    try std.testing.expectEqual(@as(i16, 1), sprite.header.y2);
    try std.testing.expectEqual(@as(usize, 12), sprite.pixels.len); // 6*2
}

test "decode rejects zero-dimension sprite" {
    // Header with X1=-1, X2=0 => width = 0 + (-1) + 1 = 0
    var data = [_]u8{0} ** 10;
    data[2] = 0xFF; // X1 low byte
    data[3] = 0xFF; // X1 high byte => X1 = -1 (little-endian i16)
    data[4] = 1; // Y1=1
    data[6] = 1; // Y2=1
    try std.testing.expectError(SpriteError.InvalidDimensions, decode(std.testing.allocator, &data));
}
