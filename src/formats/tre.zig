//! TRE (Tree) archive reader for Wing Commander: Privateer.
//! Parses the PRIV.TRE archive format: header (8 bytes), TOC entries (74 bytes each),
//! and extracts embedded file data.

const std = @import("std");

pub const HEADER_SIZE: u32 = 8;
pub const ENTRY_SIZE: u32 = 74;

pub const TreHeader = struct {
    /// Number of file entries in the archive
    entry_count: u32,
    /// Size of the table of contents in bytes (includes header)
    toc_size: u32,
};

pub const TreEntry = struct {
    /// Flag byte (0x01 = file)
    flag: u8,
    /// File path (null-terminated in archive, cleaned up here)
    path: []const u8,
    /// File offset relative to end of TOC
    offset: u32,
    /// File size in bytes
    size: u32,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *TreEntry) void {
        self.allocator.free(self.path);
    }
};

pub const TreError = error{
    InvalidHeader,
    InvalidEntry,
    ReadError,
    OutOfMemory,
    EntryOutOfBounds,
};

/// Parse the TRE archive header (first 8 bytes).
pub fn readHeader(data: []const u8) TreError!TreHeader {
    if (data.len < HEADER_SIZE) return TreError.InvalidHeader;
    return .{
        .entry_count = std.mem.readInt(u32, data[0..4], .little),
        .toc_size = std.mem.readInt(u32, data[4..8], .little),
    };
}

/// Parse a single TRE entry at the given index.
pub fn readEntry(allocator: std.mem.Allocator, data: []const u8, index: u32) !TreEntry {
    const entry_offset = HEADER_SIZE + @as(usize, index) * ENTRY_SIZE;
    if (data.len < entry_offset + ENTRY_SIZE) return TreError.InvalidEntry;

    const entry = data[entry_offset .. entry_offset + ENTRY_SIZE];

    // Path is null-terminated starting at byte 1, max 65 bytes
    const path_bytes = entry[1..66];
    const path_len = std.mem.indexOfScalar(u8, path_bytes, 0) orelse 65;

    return .{
        .flag = entry[0],
        .path = try allocator.dupe(u8, path_bytes[0..path_len]),
        .offset = std.mem.readInt(u32, entry[66..70], .little),
        .size = std.mem.readInt(u32, entry[70..74], .little),
        .allocator = allocator,
    };
}

/// Parse all TRE entries.
pub fn readAllEntries(allocator: std.mem.Allocator, data: []const u8) ![]TreEntry {
    const header = try readHeader(data);
    var entries: std.ArrayListUnmanaged(TreEntry) = .empty;
    try entries.ensureTotalCapacity(allocator, header.entry_count);
    errdefer {
        for (entries.items) |*e| e.deinit();
        entries.deinit(allocator);
    }

    for (0..header.entry_count) |i| {
        try entries.append(allocator, try readEntry(allocator, data, @intCast(i)));
    }

    return entries.toOwnedSlice(allocator);
}

/// Extract file data for a given TRE entry.
/// The data parameter should be the entire TRE archive data.
/// The entry offset is relative to the start of the TRE data (not relative to the TOC end).
pub fn extractFileData(data: []const u8, entry_offset: u32, entry_size: u32) TreError![]const u8 {
    const file_start = @as(usize, entry_offset);
    const file_end = file_start + @as(usize, entry_size);
    if (file_end > data.len) return TreError.EntryOutOfBounds;
    return data[file_start..file_end];
}

/// Find a TRE entry by path suffix (case-insensitive match on the filename portion).
pub fn findEntry(allocator: std.mem.Allocator, data: []const u8, filename: []const u8) !TreEntry {
    const header = try readHeader(data);
    for (0..header.entry_count) |i| {
        var entry = try readEntry(allocator, data, @intCast(i));
        // Check if the path ends with the requested filename
        const basename = std.fs.path.basename(entry.path);
        if (std.ascii.eqlIgnoreCase(basename, filename)) {
            return entry;
        }
        entry.deinit();
    }
    return TreError.ReadError; // not found
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "readHeader parses entry count and toc size" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    const header = try readHeader(data);
    try std.testing.expectEqual(@as(u32, 3), header.entry_count);
    // toc_size = 8 + 3*74 = 230
    try std.testing.expectEqual(@as(u32, 230), header.toc_size);
}

test "readEntry parses first entry path and metadata" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    var entry = try readEntry(allocator, data, 0);
    defer entry.deinit();

    try std.testing.expectEqual(@as(u8, 0x01), entry.flag);
    try std.testing.expectEqualStrings("..\\..\\DATA\\AIDS\\ATTITUDE.IFF", entry.path);
    try std.testing.expectEqual(@as(u32, 230), entry.offset); // toc_size = 230, file data starts there
    try std.testing.expectEqual(@as(u32, 16), entry.size);
}

test "readEntry parses second entry" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    var entry = try readEntry(allocator, data, 1);
    defer entry.deinit();

    try std.testing.expectEqualStrings("..\\..\\DATA\\AIDS\\BEHAVIOR.IFF", entry.path);
    try std.testing.expectEqual(@as(u32, 246), entry.offset); // 230 + 16 = 246
    try std.testing.expectEqual(@as(u32, 12), entry.size);
}

test "readAllEntries returns all 3 entries" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    const entries = try readAllEntries(allocator, data);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("..\\..\\DATA\\AIDS\\ATTITUDE.IFF", entries[0].path);
    try std.testing.expectEqualStrings("..\\..\\DATA\\AIDS\\BEHAVIOR.IFF", entries[1].path);
    try std.testing.expectEqualStrings("..\\..\\DATA\\APPEARNC\\GALAXY.PAK", entries[2].path);
}

test "extractFileData reads FORM header from first entry" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    var entry = try readEntry(allocator, data, 0);
    defer entry.deinit();

    const file_data = try extractFileData(data, entry.offset, entry.size);
    // First 4 bytes should be "FORM"
    try std.testing.expectEqualStrings("FORM", file_data[0..4]);
    try std.testing.expectEqual(@as(usize, 16), file_data.len);
}

test "extractFileData reads second entry with correct offset" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    var entry = try readEntry(allocator, data, 1);
    defer entry.deinit();

    const file_data = try extractFileData(data, entry.offset, entry.size);
    try std.testing.expectEqualStrings("FORM", file_data[0..4]);
    try std.testing.expectEqual(@as(usize, 12), file_data.len);
}

test "findEntry locates file by name" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    var entry = try findEntry(allocator, data, "ATTITUDE.IFF");
    defer entry.deinit();

    try std.testing.expectEqualStrings("..\\..\\DATA\\AIDS\\ATTITUDE.IFF", entry.path);
}

test "readHeader rejects too-small data" {
    const data = [_]u8{ 0, 0, 0 };
    try std.testing.expectError(TreError.InvalidHeader, readHeader(&data));
}
