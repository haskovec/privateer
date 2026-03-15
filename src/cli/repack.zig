//! Asset repacking pipeline for Wing Commander: Privateer.
//! Takes a directory of extracted assets and builds GAME.DAT (ISO 9660 + PRIV.TRE).
//! This is the reverse of extract.zig.

const std = @import("std");
const tre = @import("../formats/tre.zig");
const iso9660 = @import("../formats/iso9660.zig");

/// Result of a repack operation.
pub const RepackResult = struct {
    files_packed: u32,
    bytes_written: u64,
};

/// A file entry collected from the input directory for packing.
const FileEntry = struct {
    /// TRE-format path (e.g., "..\\..\\DATA\\AIDS\\ATTITUDE.IFF")
    tre_path: []const u8,
    /// Relative path for reading from disk (e.g., "AIDS/ATTITUDE.IFF")
    rel_path: []const u8,
    /// File data loaded from disk
    data: []const u8,

    allocator: std.mem.Allocator,

    fn deinit(self: *FileEntry) void {
        self.allocator.free(self.tre_path);
        self.allocator.free(self.rel_path);
        self.allocator.free(self.data);
    }
};

/// Convert an extracted relative path (forward slashes) to a TRE-format path.
/// Example: "AIDS/ATTITUDE.IFF" → "..\\..\\DATA\\AIDS\\ATTITUDE.IFF"
pub fn toTrePath(allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    const prefix = "..\\..\\DATA\\";
    const result = try allocator.alloc(u8, prefix.len + rel_path.len);
    @memcpy(result[0..prefix.len], prefix);
    for (rel_path, 0..) |c, i| {
        result[prefix.len + i] = if (c == '/') '\\' else c;
    }
    return result;
}

/// Build a TRE archive from a list of file entries.
/// Returns the complete TRE binary data (header + TOC + file data).
pub fn buildTre(allocator: std.mem.Allocator, entries: []const FileEntry) ![]u8 {
    const entry_count: u32 = @intCast(entries.len);
    const toc_size: u32 = tre.HEADER_SIZE + entry_count * tre.ENTRY_SIZE;

    // Calculate total file data size
    var total_data: u64 = 0;
    for (entries) |e| {
        total_data += e.data.len;
    }

    const total_size = @as(usize, toc_size) + @as(usize, @intCast(total_data));
    const buf = try allocator.alloc(u8, total_size);
    @memset(buf, 0);

    // Write header
    std.mem.writeInt(u32, buf[0..4], entry_count, .little);
    std.mem.writeInt(u32, buf[4..8], toc_size, .little);

    // Write entries and file data
    var data_offset: u32 = toc_size;
    for (entries, 0..) |e, i| {
        const entry_offset = tre.HEADER_SIZE + @as(usize, @intCast(i)) * tre.ENTRY_SIZE;
        const entry_buf = buf[entry_offset .. entry_offset + tre.ENTRY_SIZE];

        // Flag
        entry_buf[0] = 0x01;

        // Path (null-terminated, 65 bytes max)
        const path_len = @min(e.tre_path.len, 65);
        @memcpy(entry_buf[1 .. 1 + path_len], e.tre_path[0..path_len]);

        // Offset and size
        std.mem.writeInt(u32, entry_buf[66..70], data_offset, .little);
        std.mem.writeInt(u32, entry_buf[70..74], @intCast(e.data.len), .little);

        // Copy file data
        @memcpy(buf[data_offset .. data_offset + e.data.len], e.data);
        data_offset += @intCast(e.data.len);
    }

    return buf;
}

/// Build an ISO 9660 image containing a single PRIV.TRE file.
/// Returns the complete GAME.DAT binary data.
pub fn buildIso(allocator: std.mem.Allocator, tre_data: []const u8) ![]u8 {
    const sector_size = iso9660.SECTOR_SIZE;
    const pvd_sector: u32 = 16;
    const terminator_sector: u32 = 17;
    const root_dir_sector: u32 = 18;
    const tre_sector: u32 = 19;

    // Calculate total image size (pad TRE to sector boundary)
    const tre_sectors = (tre_data.len + sector_size - 1) / sector_size;
    const total_sectors = tre_sector + @as(u32, @intCast(tre_sectors));
    const image_size = @as(usize, total_sectors) * sector_size;

    const buf = try allocator.alloc(u8, image_size);
    @memset(buf, 0);

    // --- Primary Volume Descriptor at sector 16 ---
    const pvd_off = @as(usize, pvd_sector) * sector_size;
    buf[pvd_off + 0] = 0x01; // type = PVD
    @memcpy(buf[pvd_off + 1 .. pvd_off + 6], "CD001");
    buf[pvd_off + 6] = 0x01; // version

    // Volume identifier (32 bytes, space-padded)
    const vol_id = "PRIVATEER                       ";
    @memcpy(buf[pvd_off + 40 .. pvd_off + 72], vol_id);

    // Volume space size (both-endian at offset 80)
    std.mem.writeInt(u32, buf[pvd_off + 80 .. pvd_off + 84], total_sectors, .little);
    std.mem.writeInt(u32, buf[pvd_off + 84 .. pvd_off + 88], @byteSwap(total_sectors), .little);

    // Volume set size (both-endian at offset 120)
    std.mem.writeInt(u16, buf[pvd_off + 120 .. pvd_off + 122], 1, .little);
    std.mem.writeInt(u16, buf[pvd_off + 122 .. pvd_off + 124], @byteSwap(@as(u16, 1)), .little);

    // Volume sequence number (both-endian at offset 124)
    std.mem.writeInt(u16, buf[pvd_off + 124 .. pvd_off + 126], 1, .little);
    std.mem.writeInt(u16, buf[pvd_off + 126 .. pvd_off + 128], @byteSwap(@as(u16, 1)), .little);

    // Block size (both-endian at offset 128)
    std.mem.writeInt(u16, buf[pvd_off + 128 .. pvd_off + 130], @intCast(sector_size), .little);
    std.mem.writeInt(u16, buf[pvd_off + 130 .. pvd_off + 132], @byteSwap(@as(u16, @intCast(sector_size))), .little);

    // Root directory record at PVD offset 156 (34 bytes)
    const root_rec = buf[pvd_off + 156 .. pvd_off + 190];
    root_rec[0] = 34; // record length
    std.mem.writeInt(u32, root_rec[2..6], root_dir_sector, .little);
    std.mem.writeInt(u32, root_rec[6..10], @byteSwap(root_dir_sector), .little);
    std.mem.writeInt(u32, root_rec[10..14], sector_size, .little);
    std.mem.writeInt(u32, root_rec[14..18], @byteSwap(@as(u32, sector_size)), .little);
    root_rec[25] = 0x02; // flags: directory
    root_rec[32] = 1; // name length
    root_rec[33] = 0x00; // root = "."

    // --- Volume Descriptor Set Terminator at sector 17 ---
    const term_off = @as(usize, terminator_sector) * sector_size;
    buf[term_off + 0] = 0xFF; // type = terminator
    @memcpy(buf[term_off + 1 .. term_off + 6], "CD001");
    buf[term_off + 6] = 0x01; // version

    // --- Root directory at sector 18 ---
    const dir_off = @as(usize, root_dir_sector) * sector_size;
    var dir_pos: usize = 0;

    // "." entry
    {
        const rec = buf[dir_off + dir_pos .. dir_off + dir_pos + 34];
        rec[0] = 34;
        std.mem.writeInt(u32, rec[2..6], root_dir_sector, .little);
        std.mem.writeInt(u32, rec[6..10], @byteSwap(root_dir_sector), .little);
        std.mem.writeInt(u32, rec[10..14], sector_size, .little);
        std.mem.writeInt(u32, rec[14..18], @byteSwap(@as(u32, sector_size)), .little);
        rec[25] = 0x02;
        rec[32] = 1;
        rec[33] = 0x00;
        dir_pos += 34;
    }

    // ".." entry
    {
        const rec = buf[dir_off + dir_pos .. dir_off + dir_pos + 34];
        rec[0] = 34;
        std.mem.writeInt(u32, rec[2..6], root_dir_sector, .little);
        std.mem.writeInt(u32, rec[6..10], @byteSwap(root_dir_sector), .little);
        std.mem.writeInt(u32, rec[10..14], sector_size, .little);
        std.mem.writeInt(u32, rec[14..18], @byteSwap(@as(u32, sector_size)), .little);
        rec[25] = 0x02;
        rec[32] = 1;
        rec[33] = 0x01;
        dir_pos += 34;
    }

    // PRIV.TRE entry
    {
        const file_name = "PRIV.TRE;1";
        const rec_len: u8 = 33 + file_name.len + (if (file_name.len % 2 == 0) 1 else 0);
        const rec = buf[dir_off + dir_pos .. dir_off + dir_pos + rec_len];
        rec[0] = rec_len;
        std.mem.writeInt(u32, rec[2..6], tre_sector, .little);
        std.mem.writeInt(u32, rec[6..10], @byteSwap(tre_sector), .little);
        std.mem.writeInt(u32, rec[10..14], @intCast(tre_data.len), .little);
        std.mem.writeInt(u32, rec[14..18], @byteSwap(@as(u32, @intCast(tre_data.len))), .little);
        rec[25] = 0x00; // flags: file
        rec[32] = @intCast(file_name.len);
        @memcpy(rec[33 .. 33 + file_name.len], file_name);
    }

    // --- PRIV.TRE data at sector 19 ---
    const tre_off = @as(usize, tre_sector) * sector_size;
    @memcpy(buf[tre_off .. tre_off + tre_data.len], tre_data);

    return buf;
}

/// Collect all files from an extracted directory tree.
/// Walks subdirectories and builds FileEntry list sorted by path.
pub fn collectFiles(allocator: std.mem.Allocator, input_dir: []const u8) ![]FileEntry {
    var entries: std.ArrayListUnmanaged(FileEntry) = .empty;
    errdefer {
        for (entries.items) |*e| e.deinit();
        entries.deinit(allocator);
    }

    const dir = std.fs.cwd().openDir(input_dir, .{ .iterate = true }) catch return error.InputDirNotFound;
    defer @constCast(&dir).close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const rel_path = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(rel_path);

        const tre_path = try toTrePath(allocator, rel_path);
        errdefer allocator.free(tre_path);

        // Read file data
        const file = try dir.openFile(entry.path, .{});
        defer file.close();
        const stat = try file.stat();
        const data = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(data);
        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            allocator.free(data);
            allocator.free(tre_path);
            allocator.free(rel_path);
            continue;
        }

        try entries.append(allocator, .{
            .tre_path = tre_path,
            .rel_path = rel_path,
            .data = data,
            .allocator = allocator,
        });
    }

    // Sort by TRE path for deterministic output
    std.mem.sort(FileEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            return std.mem.order(u8, a.tre_path, b.tre_path) == .lt;
        }
    }.lessThan);

    return entries.toOwnedSlice(allocator);
}

/// Repack an extracted directory into a GAME.DAT ISO image.
pub fn repackAll(allocator: std.mem.Allocator, input_dir: []const u8, output_path: []const u8) !RepackResult {
    // Collect files from input directory
    const entries = try collectFiles(allocator, input_dir);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    // Build TRE archive
    const tre_data = try buildTre(allocator, entries);
    defer allocator.free(tre_data);

    // Build ISO 9660 image
    const iso_data = try buildIso(allocator, tre_data);
    defer allocator.free(iso_data);

    // Write to output file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(iso_data);

    var bytes_written: u64 = 0;
    for (entries) |e| {
        bytes_written += e.data.len;
    }

    return .{
        .files_packed = @intCast(entries.len),
        .bytes_written = bytes_written,
    };
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");
const extract = @import("extract.zig");

test "toTrePath converts extracted path to TRE format" {
    const allocator = std.testing.allocator;
    const result = try toTrePath(allocator, "AIDS/ATTITUDE.IFF");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("..\\..\\DATA\\AIDS\\ATTITUDE.IFF", result);
}

test "toTrePath converts nested path" {
    const allocator = std.testing.allocator;
    const result = try toTrePath(allocator, "SPEECH/MID01/FILE.VOC");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("..\\..\\DATA\\SPEECH\\MID01\\FILE.VOC", result);
}

test "toTrePath handles backslashes in input" {
    const allocator = std.testing.allocator;
    const result = try toTrePath(allocator, "AIDS\\ATTITUDE.IFF");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("..\\..\\DATA\\AIDS\\ATTITUDE.IFF", result);
}

test "buildTre produces valid TRE with correct header" {
    const allocator = std.testing.allocator;

    const path0 = try allocator.dupe(u8, "..\\..\\DATA\\AIDS\\TEST.IFF");
    defer allocator.free(path0);
    const data0 = try allocator.dupe(u8, "FORM_TEST_DATA!!");
    defer allocator.free(data0);
    const rel0 = try allocator.dupe(u8, "AIDS/TEST.IFF");
    defer allocator.free(rel0);

    const entries = [_]FileEntry{
        .{ .tre_path = path0, .rel_path = rel0, .data = data0, .allocator = allocator },
    };

    const tre_data = try buildTre(allocator, &entries);
    defer allocator.free(tre_data);

    // Verify header
    const header = try tre.readHeader(tre_data);
    try std.testing.expectEqual(@as(u32, 1), header.entry_count);
    try std.testing.expectEqual(@as(u32, tre.HEADER_SIZE + tre.ENTRY_SIZE), header.toc_size);

    // Verify entry
    var entry = try tre.readEntry(allocator, tre_data, 0);
    defer entry.deinit();
    try std.testing.expectEqualStrings("..\\..\\DATA\\AIDS\\TEST.IFF", entry.path);
    try std.testing.expectEqual(@as(u32, 16), entry.size);

    // Verify file data
    const file_data = try tre.extractFileData(tre_data, entry.offset, entry.size);
    try std.testing.expectEqualStrings("FORM_TEST_DATA!!", file_data);
}

test "buildTre produces valid TRE with multiple entries" {
    const allocator = std.testing.allocator;

    const path0 = try allocator.dupe(u8, "..\\..\\DATA\\AIDS\\A.IFF");
    defer allocator.free(path0);
    const data0 = try allocator.dupe(u8, "AAAA");
    defer allocator.free(data0);
    const rel0 = try allocator.dupe(u8, "AIDS/A.IFF");
    defer allocator.free(rel0);

    const path1 = try allocator.dupe(u8, "..\\..\\DATA\\AIDS\\B.IFF");
    defer allocator.free(path1);
    const data1 = try allocator.dupe(u8, "BBBBBB");
    defer allocator.free(data1);
    const rel1 = try allocator.dupe(u8, "AIDS/B.IFF");
    defer allocator.free(rel1);

    const entries = [_]FileEntry{
        .{ .tre_path = path0, .rel_path = rel0, .data = data0, .allocator = allocator },
        .{ .tre_path = path1, .rel_path = rel1, .data = data1, .allocator = allocator },
    };

    const tre_data = try buildTre(allocator, &entries);
    defer allocator.free(tre_data);

    const header = try tre.readHeader(tre_data);
    try std.testing.expectEqual(@as(u32, 2), header.entry_count);

    // Verify both files can be extracted
    var e0 = try tre.readEntry(allocator, tre_data, 0);
    defer e0.deinit();
    const f0 = try tre.extractFileData(tre_data, e0.offset, e0.size);
    try std.testing.expectEqualStrings("AAAA", f0);

    var e1 = try tre.readEntry(allocator, tre_data, 1);
    defer e1.deinit();
    const f1 = try tre.extractFileData(tre_data, e1.offset, e1.size);
    try std.testing.expectEqualStrings("BBBBBB", f1);
}

test "buildIso produces valid ISO 9660 with PRIV.TRE" {
    const allocator = std.testing.allocator;

    // Build a tiny TRE
    const path0 = try allocator.dupe(u8, "..\\..\\DATA\\TEST\\FILE.IFF");
    defer allocator.free(path0);
    const data0 = try allocator.dupe(u8, "FORM");
    defer allocator.free(data0);
    const rel0 = try allocator.dupe(u8, "TEST/FILE.IFF");
    defer allocator.free(rel0);

    const file_entries = [_]FileEntry{
        .{ .tre_path = path0, .rel_path = rel0, .data = data0, .allocator = allocator },
    };

    const tre_data = try buildTre(allocator, &file_entries);
    defer allocator.free(tre_data);

    // Build ISO
    const iso_data = try buildIso(allocator, tre_data);
    defer allocator.free(iso_data);

    // Verify PVD
    const pvd = try iso9660.readPvd(iso_data);
    try std.testing.expectEqualStrings("CD001", &pvd.standard_id);
    try std.testing.expectEqual(@as(u16, 2048), pvd.block_size);

    // Verify PRIV.TRE can be found
    const tre_info = try iso9660.findFile(allocator, iso_data, pvd, "PRIV.TRE");
    try std.testing.expectEqual(@as(u32, @intCast(tre_data.len)), tre_info.size);

    // Verify TRE data can be read back
    const read_tre = try iso9660.readFileData(iso_data, tre_info.lba, tre_info.size);
    try std.testing.expectEqualSlices(u8, tre_data, read_tre);
}

test "round-trip: extract then repack preserves file content" {
    const allocator = std.testing.allocator;

    // Build a test ISO with known content
    const path0 = try allocator.dupe(u8, "..\\..\\DATA\\AIDS\\ROUND.IFF");
    defer allocator.free(path0);
    const data0 = try allocator.dupe(u8, "FORM_ROUNDTRIP!");
    defer allocator.free(data0);
    const rel0 = try allocator.dupe(u8, "AIDS/ROUND.IFF");
    defer allocator.free(rel0);

    const file_entries = [_]FileEntry{
        .{ .tre_path = path0, .rel_path = rel0, .data = data0, .allocator = allocator },
    };

    const original_tre = try buildTre(allocator, &file_entries);
    defer allocator.free(original_tre);
    const original_iso = try buildIso(allocator, original_tre);
    defer allocator.free(original_iso);

    // Extract to temp dir
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const extract_result = try extract.extractAll(allocator, original_iso, tmp_path);
    try std.testing.expectEqual(@as(u32, 1), extract_result.files_extracted);

    // Repack from temp dir
    const repacked_entries = try collectFiles(allocator, tmp_path);
    defer {
        for (repacked_entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(repacked_entries);
    }

    const repacked_tre = try buildTre(allocator, repacked_entries);
    defer allocator.free(repacked_tre);

    // Verify repacked TRE has same content
    const header = try tre.readHeader(repacked_tre);
    try std.testing.expectEqual(@as(u32, 1), header.entry_count);

    var entry = try tre.readEntry(allocator, repacked_tre, 0);
    defer entry.deinit();
    const file_data = try tre.extractFileData(repacked_tre, entry.offset, entry.size);
    try std.testing.expectEqualStrings("FORM_ROUNDTRIP!", file_data);
}
