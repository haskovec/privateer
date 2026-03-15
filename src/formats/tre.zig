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

    // Normalize DOS backslash separators to forward slashes for cross-platform compatibility
    const path = try allocator.dupe(u8, path_bytes[0..path_len]);
    for (path) |*c| {
        if (c.* == '\\') c.* = '/';
    }

    return .{
        .flag = entry[0],
        .path = path,
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
        const basename = std.fs.path.basename(entry.path);
        if (std.ascii.eqlIgnoreCase(basename, filename)) {
            return entry;
        }
        entry.deinit();
    }
    return TreError.ReadError; // not found
}

/// Memory-mapped TRE archive handle.
/// Uses mmap for zero-copy access to the archive data, avoiding
/// a full allocation + copy of the ~90 MB file.
pub const MappedTre = struct {
    data: []align(std.heap.page_size_min) u8,

    /// Memory-map a TRE file from disk. The returned data slice is valid until
    /// `deinit()` is called. No allocator is needed for the mapping itself.
    pub fn open(path: []const u8) !MappedTre {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        const data = try std.posix.mmap(
            null,
            stat.size,
            std.posix.PROT.READ,
            std.posix.MAP{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        return .{ .data = data };
    }

    /// Unmap the file.
    pub fn deinit(self: *MappedTre) void {
        std.posix.munmap(self.data);
    }
};

/// Indexed TRE archive for O(1) filename lookups.
/// Pre-parses all entries and builds a hash map keyed by lowercase basename.
pub const TreIndex = struct {
    allocator: std.mem.Allocator,
    entries: []TreEntry,
    /// Map from lowercase basename to index in entries array.
    name_map: std.StringHashMapUnmanaged(usize),
    /// Storage for lowercase key strings.
    key_storage: std.ArrayListUnmanaged([]u8),

    pub fn build(allocator: std.mem.Allocator, data: []const u8) !TreIndex {
        const entries = try readAllEntries(allocator, data);
        errdefer {
            for (entries) |*e| {
                var entry = e.*;
                entry.deinit();
            }
            allocator.free(entries);
        }

        var name_map: std.StringHashMapUnmanaged(usize) = .empty;
        var key_storage: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (key_storage.items) |k| allocator.free(k);
            key_storage.deinit(allocator);
            name_map.deinit(allocator);
        }

        for (entries, 0..) |entry, i| {
            const basename = std.fs.path.basename(entry.path);
            const lower = try allocator.alloc(u8, basename.len);
            for (basename, 0..) |c, j| {
                lower[j] = std.ascii.toLower(c);
            }
            try key_storage.append(allocator, lower);
            try name_map.put(allocator, lower, i);
        }

        return .{
            .allocator = allocator,
            .entries = entries,
            .name_map = name_map,
            .key_storage = key_storage,
        };
    }

    pub fn deinit(self: *TreIndex) void {
        for (self.entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        self.allocator.free(self.entries);
        for (self.key_storage.items) |k| self.allocator.free(k);
        self.key_storage.deinit(self.allocator);
        self.name_map.deinit(self.allocator);
    }

    /// Find entry by filename (case-insensitive basename match). Returns null if not found.
    pub fn findEntry(self: *const TreIndex, filename: []const u8) ?*const TreEntry {
        // Convert lookup key to lowercase on the stack
        var buf: [128]u8 = undefined;
        if (filename.len > buf.len) return null;
        for (filename, 0..) |c, i| {
            buf[i] = std.ascii.toLower(c);
        }
        const key = buf[0..filename.len];
        const idx = self.name_map.get(key) orelse return null;
        return &self.entries[idx];
    }

    pub fn count(self: *const TreIndex) usize {
        return self.entries.len;
    }
};

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
    try std.testing.expectEqualStrings("../../DATA/AIDS/ATTITUDE.IFF", entry.path);
    try std.testing.expectEqual(@as(u32, 230), entry.offset); // toc_size = 230, file data starts there
    try std.testing.expectEqual(@as(u32, 16), entry.size);
}

test "readEntry parses second entry" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    var entry = try readEntry(allocator, data, 1);
    defer entry.deinit();

    try std.testing.expectEqualStrings("../../DATA/AIDS/BEHAVIOR.IFF", entry.path);
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
    try std.testing.expectEqualStrings("../../DATA/AIDS/ATTITUDE.IFF", entries[0].path);
    try std.testing.expectEqualStrings("../../DATA/AIDS/BEHAVIOR.IFF", entries[1].path);
    try std.testing.expectEqualStrings("../../DATA/APPEARNC/GALAXY.PAK", entries[2].path);
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

    try std.testing.expectEqualStrings("../../DATA/AIDS/ATTITUDE.IFF", entry.path);
}

test "readHeader rejects too-small data" {
    const data = [_]u8{ 0, 0, 0 };
    try std.testing.expectError(TreError.InvalidHeader, readHeader(&data));
}

// --- TreIndex tests ---

test "TreIndex: build from entries and lookup by filename" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    var index = try TreIndex.build(allocator, data);
    defer index.deinit();

    const entry = index.findEntry("ATTITUDE.IFF");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("../../DATA/AIDS/ATTITUDE.IFF", entry.?.path);
}

test "TreIndex: case-insensitive lookup" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    var index = try TreIndex.build(allocator, data);
    defer index.deinit();

    const entry = index.findEntry("attitude.iff");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("../../DATA/AIDS/ATTITUDE.IFF", entry.?.path);
}

test "TreIndex: lookup nonexistent file returns null" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    var index = try TreIndex.build(allocator, data);
    defer index.deinit();

    const entry = index.findEntry("NONEXISTENT.IFF");
    try std.testing.expect(entry == null);
}

test "TreIndex: extract file data via indexed entry" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    var index = try TreIndex.build(allocator, data);
    defer index.deinit();

    const entry = index.findEntry("ATTITUDE.IFF").?;
    const file_data = try extractFileData(data, entry.offset, entry.size);
    try std.testing.expectEqualStrings("FORM", file_data[0..4]);
}

test "TreIndex: all entries accessible" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(data);

    var index = try TreIndex.build(allocator, data);
    defer index.deinit();

    try std.testing.expect(index.findEntry("ATTITUDE.IFF") != null);
    try std.testing.expect(index.findEntry("BEHAVIOR.IFF") != null);
    try std.testing.expect(index.findEntry("GALAXY.PAK") != null);
    try std.testing.expectEqual(@as(usize, 3), index.count());
}

// --- MappedTre tests ---

test "MappedTre: memory-map fixture file and parse header" {
    // Write fixture to a temp file so we can mmap it
    const allocator = std.testing.allocator;
    const fixture = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(fixture);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    {
        const f = try tmp_dir.dir.createFile("test.tre", .{});
        defer f.close();
        try f.writeAll(fixture);
    }

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, "test.tre");
    defer allocator.free(tmp_path);

    var mapped = try MappedTre.open(tmp_path);
    defer mapped.deinit();

    // Should be able to parse the header from mapped data
    const header = try readHeader(mapped.data);
    try std.testing.expectEqual(@as(u32, 3), header.entry_count);
}

test "MappedTre: build TreIndex from mapped data" {
    const allocator = std.testing.allocator;
    const fixture = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(fixture);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    {
        const f = try tmp_dir.dir.createFile("test.tre", .{});
        defer f.close();
        try f.writeAll(fixture);
    }

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, "test.tre");
    defer allocator.free(tmp_path);

    var mapped = try MappedTre.open(tmp_path);
    defer mapped.deinit();

    var index = try TreIndex.build(allocator, mapped.data);
    defer index.deinit();

    try std.testing.expect(index.findEntry("ATTITUDE.IFF") != null);
    try std.testing.expectEqual(@as(usize, 3), index.count());
}
