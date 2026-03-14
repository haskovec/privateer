//! SHP (Shape/Font) file parser for Wing Commander: Privateer.
//! Parses Origin's SHP format used for fonts and mouse cursors.
//! Structure: 4-byte file size header, offset table of u32 LE entries,
//! followed by RLE-encoded sprite data (decoded via sprite.zig).

const std = @import("std");
const sprite = @import("sprite.zig");

/// Minimum valid SHP file: file_size(4) + one offset(4) + minimal sprite header(8) = 16.
pub const MIN_FILE_SIZE: usize = 16;

/// Size of the file-size field at offset 0.
pub const FILE_SIZE_FIELD: usize = 4;

/// Size of each offset table entry.
pub const OFFSET_ENTRY_SIZE: usize = 4;

pub const ShpError = error{
    /// File too small to contain a valid SHP header.
    InvalidSize,
    /// Offset table is malformed (first offset inconsistent or unaligned).
    InvalidOffsetTable,
    /// A sprite offset points outside the file data.
    OffsetOutOfBounds,
    /// Index passed to decodeSprite exceeds sprite count.
    IndexOutOfBounds,
    OutOfMemory,
};

/// A parsed SHP file with an offset table into the raw data.
pub const ShapeFile = struct {
    /// Offsets to each sprite's RLE data (absolute positions in the file).
    offsets: []u32,
    /// Total file size from header.
    file_size: u32,
    /// Raw file data (not owned -- caller retains ownership).
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ShapeFile) void {
        self.allocator.free(self.offsets);
    }

    /// Number of sprites/shapes in this SHP file.
    pub fn spriteCount(self: ShapeFile) usize {
        return self.offsets.len;
    }

    /// Decode the sprite at the given index.
    /// Caller owns the returned Sprite and must call deinit() on it.
    pub fn decodeSprite(self: ShapeFile, allocator: std.mem.Allocator, index: usize) (ShpError || sprite.SpriteError)!sprite.Sprite {
        if (index >= self.offsets.len) return ShpError.IndexOutOfBounds;

        const offset: usize = self.offsets[index];
        if (offset >= self.data.len) return ShpError.OffsetOutOfBounds;

        // Determine end boundary: next sprite's offset, or end of file data
        const end: usize = if (index + 1 < self.offsets.len)
            @as(usize, self.offsets[index + 1])
        else
            self.data.len;

        if (end > self.data.len) return ShpError.OffsetOutOfBounds;

        return sprite.decode(allocator, self.data[offset..end]);
    }
};

/// Parse an SHP file from raw bytes.
/// Returns a ShapeFile with the offset table (caller must call deinit()).
/// The data slice is NOT owned by the ShapeFile -- caller must keep it alive.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) ShpError!ShapeFile {
    if (data.len < MIN_FILE_SIZE) return ShpError.InvalidSize;

    // Read total file size from first 4 bytes
    const file_size = std.mem.readInt(u32, data[0..4], .little);

    // Read first offset to determine the number of entries
    const first_offset = std.mem.readInt(u32, data[4..8], .little);

    // first_offset must be >= 8 (file_size field + at least one offset entry)
    if (first_offset < FILE_SIZE_FIELD + OFFSET_ENTRY_SIZE) return ShpError.InvalidOffsetTable;

    // The offset table spans bytes 4..(first_offset), so its size must be a multiple of 4
    const table_bytes = first_offset - FILE_SIZE_FIELD;
    if (table_bytes % OFFSET_ENTRY_SIZE != 0) return ShpError.InvalidOffsetTable;

    const count = table_bytes / OFFSET_ENTRY_SIZE;

    // Validate that the offset table fits within the data
    if (first_offset > data.len) return ShpError.InvalidSize;

    // Read all offsets
    const offsets = try allocator.alloc(u32, count);
    errdefer allocator.free(offsets);

    for (0..count) |i| {
        const off = FILE_SIZE_FIELD + i * OFFSET_ENTRY_SIZE;
        offsets[i] = std.mem.readInt(u32, data[off..][0..4], .little);

        // Validate each offset is within bounds
        if (offsets[i] >= data.len) {
            allocator.free(offsets);
            return ShpError.OffsetOutOfBounds;
        }
    }

    return .{
        .offsets = offsets,
        .file_size = file_size,
        .data = data,
        .allocator = allocator,
    };
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "parse SHP offset table from test fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_shp.bin");
    defer allocator.free(data);

    var shp = try parse(allocator, data);
    defer shp.deinit();

    // test_shp.bin has 3 sprites
    try std.testing.expectEqual(@as(usize, 3), shp.spriteCount());
    // First offset should be 16 (4 + 3*4)
    try std.testing.expectEqual(@as(u32, 16), shp.offsets[0]);
}

test "parse SHP single-sprite file" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_shp_single.bin");
    defer allocator.free(data);

    var shp = try parse(allocator, data);
    defer shp.deinit();

    try std.testing.expectEqual(@as(usize, 1), shp.spriteCount());
    try std.testing.expectEqual(@as(u32, 8), shp.offsets[0]);
}

test "decodeSprite extracts individual shapes by index" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_shp.bin");
    defer allocator.free(data);

    var shp = try parse(allocator, data);
    defer shp.deinit();

    // Sprite 0: 4x4 with pixels [1..16]
    {
        var s = try shp.decodeSprite(allocator, 0);
        defer s.deinit();
        try std.testing.expectEqual(@as(u16, 4), s.width);
        try std.testing.expectEqual(@as(u16, 4), s.height);
        try testing_helpers.expectBytes(&[_]u8{ 1, 2, 3, 4 }, s.pixels[0..4]);
        try testing_helpers.expectBytes(&[_]u8{ 13, 14, 15, 16 }, s.pixels[12..16]);
    }

    // Sprite 1: 2x2 with pixels [0xAA, 0xBB, 0xCC, 0xDD]
    {
        var s = try shp.decodeSprite(allocator, 1);
        defer s.deinit();
        try std.testing.expectEqual(@as(u16, 2), s.width);
        try std.testing.expectEqual(@as(u16, 2), s.height);
        try testing_helpers.expectBytes(&[_]u8{ 0xAA, 0xBB }, s.pixels[0..2]);
        try testing_helpers.expectBytes(&[_]u8{ 0xCC, 0xDD }, s.pixels[2..4]);
    }

    // Sprite 2: 3x2
    {
        var s = try shp.decodeSprite(allocator, 2);
        defer s.deinit();
        try std.testing.expectEqual(@as(u16, 3), s.width);
        try std.testing.expectEqual(@as(u16, 2), s.height);
        try testing_helpers.expectBytes(&[_]u8{ 10, 20, 30 }, s.pixels[0..3]);
        try testing_helpers.expectBytes(&[_]u8{ 40, 50, 60 }, s.pixels[3..6]);
    }
}

test "decodeSprite from single-sprite SHP" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_shp_single.bin");
    defer allocator.free(data);

    var shp = try parse(allocator, data);
    defer shp.deinit();

    var s = try shp.decodeSprite(allocator, 0);
    defer s.deinit();

    try std.testing.expectEqual(@as(u16, 2), s.width);
    try std.testing.expectEqual(@as(u16, 2), s.height);
    try testing_helpers.expectBytes(&[_]u8{ 0xFF, 0xFE }, s.pixels[0..2]);
    try testing_helpers.expectBytes(&[_]u8{ 0xFD, 0xFC }, s.pixels[2..4]);
}

test "decodeSprite rejects out-of-bounds index" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_shp.bin");
    defer allocator.free(data);

    var shp = try parse(allocator, data);
    defer shp.deinit();

    try std.testing.expectError(ShpError.IndexOutOfBounds, shp.decodeSprite(allocator, 3));
    try std.testing.expectError(ShpError.IndexOutOfBounds, shp.decodeSprite(allocator, 99));
}

test "parse rejects too-small data" {
    const data = [_]u8{0} ** 8; // below MIN_FILE_SIZE
    try std.testing.expectError(ShpError.InvalidSize, parse(std.testing.allocator, &data));
}

test "parse rejects invalid offset table alignment" {
    // Craft data where first_offset - 4 is not divisible by 4
    var data = [_]u8{0} ** 20;
    // file_size = 20
    std.mem.writeInt(u32, data[0..4], 20, .little);
    // first_offset = 7 (not aligned: (7-4)%4 = 3 != 0)
    std.mem.writeInt(u32, data[4..8], 7, .little);

    try std.testing.expectError(ShpError.InvalidOffsetTable, parse(std.testing.allocator, &data));
}

test "parse stores file size from header" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_shp.bin");
    defer allocator.free(data);

    var shp = try parse(allocator, data);
    defer shp.deinit();

    try std.testing.expectEqual(@as(u32, 120), shp.file_size);
}
