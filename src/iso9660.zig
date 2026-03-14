//! ISO 9660 file system reader for CD-ROM images (e.g., GAME.DAT).
//! Parses the Primary Volume Descriptor and directory records to locate
//! files within the image.

const std = @import("std");

pub const SECTOR_SIZE: u32 = 2048;
const PVD_SECTOR: u32 = 16;

pub const PrimaryVolumeDescriptor = struct {
    /// "CD001"
    standard_id: [5]u8,
    /// Volume identifier (trimmed)
    volume_id: [32]u8,
    /// Total number of sectors
    volume_space_size: u32,
    /// Logical block size (usually 2048)
    block_size: u16,
    /// Root directory record LBA
    root_dir_lba: u32,
    /// Root directory record data length
    root_dir_size: u32,
};

pub const DirectoryRecord = struct {
    /// Length of this record
    record_len: u8,
    /// LBA of the file/directory extent
    extent_lba: u32,
    /// Size of the file/directory data in bytes
    data_size: u32,
    /// True if this is a directory
    is_directory: bool,
    /// File identifier (name), without version suffix
    name: []const u8,

    allocator: ?std.mem.Allocator,

    pub fn deinit(self: *DirectoryRecord) void {
        if (self.allocator) |a| {
            a.free(self.name);
        }
    }
};

/// Errors during ISO 9660 parsing.
pub const Iso9660Error = error{
    InvalidPvd,
    InvalidDirectoryRecord,
    FileNotFound,
    ReadError,
    OutOfMemory,
};

/// Read the Primary Volume Descriptor from an ISO image.
pub fn readPvd(data: []const u8) Iso9660Error!PrimaryVolumeDescriptor {
    const offset = PVD_SECTOR * SECTOR_SIZE;
    if (data.len < offset + SECTOR_SIZE) return Iso9660Error.InvalidPvd;

    const pvd = data[offset..];
    // Check type code = 1
    if (pvd[0] != 0x01) return Iso9660Error.InvalidPvd;
    // Check standard identifier = "CD001"
    if (!std.mem.eql(u8, pvd[1..6], "CD001")) return Iso9660Error.InvalidPvd;

    var result: PrimaryVolumeDescriptor = undefined;
    @memcpy(&result.standard_id, pvd[1..6]);
    @memcpy(&result.volume_id, pvd[40..72]);

    // Volume space size (LE at offset 80)
    result.volume_space_size = std.mem.readInt(u32, pvd[80..84], .little);
    // Block size (LE at offset 128)
    result.block_size = std.mem.readInt(u16, pvd[128..130], .little);
    // Root directory record at offset 156
    result.root_dir_lba = std.mem.readInt(u32, pvd[158..162], .little);
    result.root_dir_size = std.mem.readInt(u32, pvd[166..170], .little);

    return result;
}

/// Parse directory records from a directory extent.
pub fn readDirectory(allocator: std.mem.Allocator, data: []const u8, lba: u32, size: u32) ![]DirectoryRecord {
    const offset = @as(usize, lba) * SECTOR_SIZE;
    if (data.len < offset + size) return Iso9660Error.ReadError;

    const dir_data = data[offset .. offset + size];
    var records: std.ArrayListUnmanaged(DirectoryRecord) = .empty;
    errdefer {
        for (records.items) |*r| r.deinit();
        records.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < dir_data.len) {
        const rec_len = dir_data[pos];
        if (rec_len == 0) break; // end of directory

        if (pos + rec_len > dir_data.len) break;

        const rec = dir_data[pos .. pos + rec_len];
        const name_len = rec[32];
        const raw_name = rec[33 .. 33 + name_len];

        // Skip "." (0x00) and ".." (0x01) entries
        if (name_len == 1 and (raw_name[0] == 0x00 or raw_name[0] == 0x01)) {
            pos += rec_len;
            continue;
        }

        // Strip ";1" version suffix if present
        var name_end: usize = name_len;
        for (raw_name, 0..) |ch, i| {
            if (ch == ';') {
                name_end = i;
                break;
            }
        }

        const name = try allocator.dupe(u8, raw_name[0..name_end]);

        try records.append(allocator, .{
            .record_len = rec_len,
            .extent_lba = std.mem.readInt(u32, rec[2..6], .little),
            .data_size = std.mem.readInt(u32, rec[10..14], .little),
            .is_directory = (rec[25] & 0x02) != 0,
            .name = name,
            .allocator = allocator,
        });

        pos += rec_len;
    }

    return records.toOwnedSlice(allocator);
}

/// Find a file by name in the root directory and return its LBA and size.
pub fn findFile(allocator: std.mem.Allocator, data: []const u8, pvd: PrimaryVolumeDescriptor, name: []const u8) !struct { lba: u32, size: u32 } {
    const records = try readDirectory(allocator, data, pvd.root_dir_lba, pvd.root_dir_size);
    defer {
        for (records) |*r| {
            var rec = r.*;
            rec.deinit();
        }
        allocator.free(records);
    }

    for (records) |rec| {
        if (std.mem.eql(u8, rec.name, name)) {
            return .{ .lba = rec.extent_lba, .size = rec.data_size };
        }
    }
    return Iso9660Error.FileNotFound;
}

/// Read file data from the ISO image given its LBA and size.
pub fn readFileData(data: []const u8, lba: u32, size: u32) Iso9660Error![]const u8 {
    const offset = @as(usize, lba) * SECTOR_SIZE;
    if (data.len < offset + size) return Iso9660Error.ReadError;
    return data[offset .. offset + size];
}

// --- Tests ---

const testing_helpers = @import("testing.zig");

test "readPvd parses CD001 signature from test ISO" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iso.bin");
    defer allocator.free(data);

    const pvd = try readPvd(data);
    try std.testing.expectEqualStrings("CD001", &pvd.standard_id);
}

test "readPvd parses volume identifier" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iso.bin");
    defer allocator.free(data);

    const pvd = try readPvd(data);
    // Volume ID is "PRIVATEER_TEST" padded with spaces
    const trimmed = std.mem.trimRight(u8, &pvd.volume_id, " ");
    try std.testing.expectEqualStrings("PRIVATEER_TEST", trimmed);
}

test "readPvd parses volume size and block size" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iso.bin");
    defer allocator.free(data);

    const pvd = try readPvd(data);
    try std.testing.expectEqual(@as(u32, 50), pvd.volume_space_size);
    try std.testing.expectEqual(@as(u16, 2048), pvd.block_size);
}

test "readDirectory finds PRIV.TRE in root directory" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iso.bin");
    defer allocator.free(data);

    const pvd = try readPvd(data);
    const records = try readDirectory(allocator, data, pvd.root_dir_lba, pvd.root_dir_size);
    defer {
        for (records) |*r| {
            var rec = r.*;
            rec.deinit();
        }
        allocator.free(records);
    }

    // Should have 2 entries: PRIV.TRE and LICENSE.TXT (. and .. are skipped)
    try std.testing.expectEqual(@as(usize, 2), records.len);

    // First non-dot entry should be PRIV.TRE
    try std.testing.expectEqualStrings("PRIV.TRE", records[0].name);
    try std.testing.expect(!records[0].is_directory);
    try std.testing.expectEqual(@as(u32, 27), records[0].extent_lba);
    try std.testing.expectEqual(@as(u32, 1024), records[0].data_size);
}

test "findFile locates PRIV.TRE by name" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iso.bin");
    defer allocator.free(data);

    const pvd = try readPvd(data);
    const result = try findFile(allocator, data, pvd, "PRIV.TRE");
    try std.testing.expectEqual(@as(u32, 27), result.lba);
    try std.testing.expectEqual(@as(u32, 1024), result.size);
}

test "findFile returns error for nonexistent file" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iso.bin");
    defer allocator.free(data);

    const pvd = try readPvd(data);
    const result = findFile(allocator, data, pvd, "NOPE.TXT");
    try std.testing.expectError(Iso9660Error.FileNotFound, result);
}

test "readFileData reads correct bytes at LBA" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iso.bin");
    defer allocator.free(data);

    const file_data = try readFileData(data, 27, 4);
    // First 4 bytes at sector 27 should be 0x00, 0x01, 0x02, 0x03
    const expected = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    try testing_helpers.expectBytes(&expected, file_data);
}

test "readPvd rejects invalid data" {
    const data = [_]u8{0} ** (17 * 2048);
    try std.testing.expectError(Iso9660Error.InvalidPvd, readPvd(&data));
}
