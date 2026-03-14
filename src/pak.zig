//! PAK (Packed Resource) file parser for Wing Commander: Privateer.
//! Parses Origin's PAK format used for cockpit graphics, landing screens, and UI.
//! Structure: 4-byte file length header, two-level offset tables with marker bytes,
//! followed by resource data (typically IFF FORM chunks).

const std = @import("std");

/// Minimum valid PAK file: file_size(4) + at least one table entry(4).
pub const MIN_FILE_SIZE: usize = 8;

/// Size of the file length field at offset 0.
pub const FILE_SIZE_FIELD: usize = 4;

/// Size of each offset table entry (3-byte offset + 1-byte marker).
pub const ENTRY_SIZE: usize = 4;

/// Marker: offset points to a Level 2 sub-table.
pub const MARKER_SUBTABLE: u8 = 0xC1;
/// Marker: offset points directly to resource data.
pub const MARKER_DATA: u8 = 0xE0;
/// Marker: unused/invalid slot (skip this entry).
pub const MARKER_UNUSED: u8 = 0xFF;
/// Marker: end of offset table.
pub const MARKER_END: u8 = 0x00;

pub const PakError = error{
    /// File too small to contain a valid PAK header.
    InvalidSize,
    /// No valid resources found in the PAK file.
    InvalidFormat,
    /// Unknown marker byte in offset table.
    InvalidMarker,
    /// An offset points outside the file data.
    OffsetOutOfBounds,
    /// Index exceeds resource count.
    IndexOutOfBounds,
    OutOfMemory,
};

/// A resource entry with offset and computed size within the PAK file.
pub const PakEntry = struct {
    offset: u32,
    size: u32,
};

/// A parsed PAK file with a flat list of all resource entries.
pub const PakFile = struct {
    /// Total file size from header.
    file_size: u32,
    /// Flat list of resource entries (all data pointers from L1 and L2 tables).
    entries: []PakEntry,
    /// Raw file data (not owned -- caller retains ownership).
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PakFile) void {
        self.allocator.free(self.entries);
    }

    /// Number of resources in this PAK file.
    pub fn resourceCount(self: PakFile) usize {
        return self.entries.len;
    }

    /// Get the raw data for the resource at the given index.
    pub fn getResource(self: PakFile, index: usize) PakError![]const u8 {
        if (index >= self.entries.len) return PakError.IndexOutOfBounds;
        const entry = self.entries[index];
        const end: usize = @as(usize, entry.offset) + @as(usize, entry.size);
        if (end > self.data.len) return PakError.OffsetOutOfBounds;
        return self.data[entry.offset..end];
    }
};

/// Read a 3-byte little-endian offset from data at the given position.
fn readOffset3(data: []const u8, pos: usize) u32 {
    return @as(u32, data[pos]) |
        (@as(u32, data[pos + 1]) << 8) |
        (@as(u32, data[pos + 2]) << 16);
}

/// Scan an offset table (L1 or L2) and count data (E0) entries.
/// For L1 tables, also recurses into C1 sub-tables. If a C1 entry points to
/// a location that doesn't contain valid sub-table entries, it is treated as
/// a direct data pointer instead (some game files use C1 for data sections).
/// Tables may lack an explicit 0x00 end marker; scanning stops when the read
/// position reaches or exceeds the minimum offset seen so far (implicit end).
fn countEntries(data: []const u8, table_start: usize, recurse: bool) PakError!usize {
    var count: usize = 0;
    var pos = table_start;
    var min_offset: usize = data.len;
    while (pos + ENTRY_SIZE <= data.len and pos < min_offset) {
        const marker = data[pos + 3];
        if (marker == MARKER_END) break;

        const offset: usize = readOffset3(data, pos);
        pos += ENTRY_SIZE;

        switch (marker) {
            MARKER_DATA => {
                if (offset >= data.len) return PakError.OffsetOutOfBounds;
                if (offset < min_offset) min_offset = offset;
                count += 1;
            },
            MARKER_SUBTABLE => {
                if (!recurse) return PakError.InvalidMarker;
                if (offset >= data.len) return PakError.OffsetOutOfBounds;
                if (offset < min_offset) min_offset = offset;
                // Try scanning as a sub-table; if no valid entries found,
                // treat this C1 entry as a direct data pointer.
                const sub_count = countEntries(data, offset, false) catch 0;
                if (sub_count > 0) {
                    count += sub_count;
                } else {
                    count += 1; // fallback: treat as data
                }
            },
            MARKER_UNUSED => {
                // Skip unused/sentinel entries (e.g. SPEECH.PAK)
            },
            else => break, // Unknown marker = implicit end of table
        }
    }
    return count;
}

/// Collect data (E0) offsets from an offset table into `offsets` starting at `write_idx`.
/// Returns the number of entries written.
fn collectOffsets(data: []const u8, table_start: usize, recurse: bool, offsets: []u32, write_idx: usize) PakError!usize {
    var idx = write_idx;
    var pos = table_start;
    var min_offset: usize = data.len;
    while (pos + ENTRY_SIZE <= data.len and pos < min_offset) {
        const marker = data[pos + 3];
        if (marker == MARKER_END) break;

        const offset: usize = readOffset3(data, pos);
        pos += ENTRY_SIZE;

        switch (marker) {
            MARKER_DATA => {
                if (offset >= data.len) return PakError.OffsetOutOfBounds;
                if (offset < min_offset) min_offset = offset;
                offsets[idx] = @intCast(offset);
                idx += 1;
            },
            MARKER_SUBTABLE => {
                if (!recurse) return PakError.InvalidMarker;
                if (offset >= data.len) return PakError.OffsetOutOfBounds;
                if (offset < min_offset) min_offset = offset;
                // Try scanning as a sub-table; if no valid entries found,
                // treat this C1 entry as a direct data pointer.
                const sub_count = countEntries(data, offset, false) catch 0;
                if (sub_count > 0) {
                    idx = try collectOffsets(data, offset, false, offsets, idx);
                } else {
                    offsets[idx] = @intCast(offset);
                    idx += 1;
                }
            },
            MARKER_UNUSED => {
                // Skip unused/sentinel entries
            },
            else => break, // Unknown marker = implicit end of table
        }
    }
    return idx;
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) PakError!PakFile {
    if (data.len < MIN_FILE_SIZE) return PakError.InvalidSize;

    const file_size = std.mem.readInt(u32, data[0..4], .little);

    // Pass 1: count all data entries
    const count = try countEntries(data, FILE_SIZE_FIELD, true);
    if (count == 0) return PakError.InvalidFormat;

    // Pass 2: collect all data offsets
    const offsets = try allocator.alloc(u32, count);
    defer allocator.free(offsets);
    _ = try collectOffsets(data, FILE_SIZE_FIELD, true, offsets, 0);

    // Sort a copy of offsets to compute resource sizes
    const sorted = try allocator.alloc(u32, count);
    defer allocator.free(sorted);
    @memcpy(sorted, offsets);

    // Insertion sort (arrays are small, typically < 100 entries)
    for (1..count) |i| {
        var j = i;
        while (j > 0) {
            if (sorted[j - 1] <= sorted[j]) break;
            const tmp = sorted[j];
            sorted[j] = sorted[j - 1];
            sorted[j - 1] = tmp;
            j -= 1;
        }
    }

    // Build entries with computed sizes
    const entries = try allocator.alloc(PakEntry, count);
    errdefer allocator.free(entries);

    for (offsets, 0..) |off, i| {
        // Find the next offset after this one in sorted order
        var next_off: u32 = @intCast(data.len);
        for (sorted) |s| {
            if (s > off) {
                next_off = s;
                break;
            }
        }
        entries[i] = .{
            .offset = off,
            .size = next_off - off,
        };
    }

    return .{
        .file_size = file_size,
        .entries = entries,
        .data = data,
        .allocator = allocator,
    };
}

// --- Tests ---

const testing_helpers = @import("testing.zig");

test "parse PAK header and direct E0 entries" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_pak.bin");
    defer allocator.free(data);

    var pak = try parse(allocator, data);
    defer pak.deinit();

    try std.testing.expectEqual(@as(u32, 40), pak.file_size);
    try std.testing.expectEqual(@as(usize, 3), pak.resourceCount());
}

test "parse PAK L1 offset table entries" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_pak.bin");
    defer allocator.free(data);

    var pak = try parse(allocator, data);
    defer pak.deinit();

    // Entry 0: offset=20, size=8
    try std.testing.expectEqual(@as(u32, 20), pak.entries[0].offset);
    try std.testing.expectEqual(@as(u32, 8), pak.entries[0].size);

    // Entry 1: offset=28, size=6
    try std.testing.expectEqual(@as(u32, 28), pak.entries[1].offset);
    try std.testing.expectEqual(@as(u32, 6), pak.entries[1].size);

    // Entry 2: offset=34, size=6
    try std.testing.expectEqual(@as(u32, 34), pak.entries[2].offset);
    try std.testing.expectEqual(@as(u32, 6), pak.entries[2].size);
}

test "extract resource data from PAK" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_pak.bin");
    defer allocator.free(data);

    var pak = try parse(allocator, data);
    defer pak.deinit();

    // Resource 0: 8 bytes [0x01..0x08]
    const r0 = try pak.getResource(0);
    try testing_helpers.expectBytes(&[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, r0);

    // Resource 1: 6 bytes [0xAA..0xAF]
    const r1 = try pak.getResource(1);
    try testing_helpers.expectBytes(&[_]u8{ 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF }, r1);

    // Resource 2: 6 bytes [0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA]
    const r2 = try pak.getResource(2);
    try testing_helpers.expectBytes(&[_]u8{ 0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA }, r2);
}

test "parse PAK with L2 sub-tables" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_pak_l2.bin");
    defer allocator.free(data);

    var pak = try parse(allocator, data);
    defer pak.deinit();

    try std.testing.expectEqual(@as(u32, 52), pak.file_size);
    try std.testing.expectEqual(@as(usize, 3), pak.resourceCount());

    // Sub-table resources come first (from L1 entry 0's sub-table)
    // Sub-resource 0: offset=28, size=8
    try std.testing.expectEqual(@as(u32, 28), pak.entries[0].offset);
    try std.testing.expectEqual(@as(u32, 8), pak.entries[0].size);

    // Sub-resource 1: offset=36, size=4
    try std.testing.expectEqual(@as(u32, 36), pak.entries[1].offset);
    try std.testing.expectEqual(@as(u32, 4), pak.entries[1].size);

    // Direct resource: offset=40, size=12
    try std.testing.expectEqual(@as(u32, 40), pak.entries[2].offset);
    try std.testing.expectEqual(@as(u32, 12), pak.entries[2].size);

    // Verify resource data
    const r0 = try pak.getResource(0);
    try testing_helpers.expectBytes(&[_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 }, r0);

    const r1 = try pak.getResource(1);
    try testing_helpers.expectBytes(&[_]u8{ 0x21, 0x22, 0x23, 0x24 }, r1);

    const r2 = try pak.getResource(2);
    try std.testing.expectEqual(@as(usize, 12), r2.len);
    try testing_helpers.expectBytes(&[_]u8{ 0x31, 0x32, 0x33, 0x34 }, r2[0..4]);
}

test "getResource rejects out-of-bounds index" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_pak.bin");
    defer allocator.free(data);

    var pak = try parse(allocator, data);
    defer pak.deinit();

    try std.testing.expectError(PakError.IndexOutOfBounds, pak.getResource(3));
    try std.testing.expectError(PakError.IndexOutOfBounds, pak.getResource(99));
}

test "parse rejects too-small data" {
    const data = [_]u8{0} ** 4; // below MIN_FILE_SIZE
    try std.testing.expectError(PakError.InvalidSize, parse(std.testing.allocator, &data));
}

test "parse stores file size from header" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_pak.bin");
    defer allocator.free(data);

    var pak = try parse(allocator, data);
    defer pak.deinit();

    try std.testing.expectEqual(@as(u32, 40), pak.file_size);
}

test "parse PAK with no end marker (implicit table end)" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_pak_noend.bin");
    defer allocator.free(data);

    var pak = try parse(allocator, data);
    defer pak.deinit();

    try std.testing.expectEqual(@as(u32, 34), pak.file_size);
    try std.testing.expectEqual(@as(usize, 3), pak.resourceCount());

    // Resource 0: offset=16, size=6
    try std.testing.expectEqual(@as(u32, 16), pak.entries[0].offset);
    try std.testing.expectEqual(@as(u32, 6), pak.entries[0].size);

    // Resource 1: offset=22, size=4
    try std.testing.expectEqual(@as(u32, 22), pak.entries[1].offset);
    try std.testing.expectEqual(@as(u32, 4), pak.entries[1].size);

    // Resource 2: offset=26, size=8
    try std.testing.expectEqual(@as(u32, 26), pak.entries[2].offset);
    try std.testing.expectEqual(@as(u32, 8), pak.entries[2].size);

    // Verify resource data
    const r0 = try pak.getResource(0);
    try testing_helpers.expectBytes(&[_]u8{ 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6 }, r0);

    const r1 = try pak.getResource(1);
    try testing_helpers.expectBytes(&[_]u8{ 0xB1, 0xB2, 0xB3, 0xB4 }, r1);
}

test "parse PAK with FF unused marker entries" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_pak_ff.bin");
    defer allocator.free(data);

    var pak = try parse(allocator, data);
    defer pak.deinit();

    try std.testing.expectEqual(@as(u32, 28), pak.file_size);
    // FF entries are skipped, so only 2 data entries
    try std.testing.expectEqual(@as(usize, 2), pak.resourceCount());

    const r0 = try pak.getResource(0);
    try testing_helpers.expectBytes(&[_]u8{ 0xD1, 0xD2, 0xD3, 0xD4 }, r0);

    const r1 = try pak.getResource(1);
    try testing_helpers.expectBytes(&[_]u8{ 0xE1, 0xE2, 0xE3, 0xE4 }, r1);
}
