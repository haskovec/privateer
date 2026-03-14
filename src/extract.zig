//! Asset extraction pipeline for Wing Commander: Privateer.
//! Extracts all files from GAME.DAT (ISO 9660) → PRIV.TRE → directory tree.

const std = @import("std");
const iso9660 = @import("iso9660.zig");
const tre = @import("tre.zig");

pub const ExtractError = error{
    GameDatNotFound,
    TreNotFound,
    InvalidPath,
    CreateDirFailed,
    WriteFailed,
    OutOfMemory,
};

/// Result of an extraction run.
pub const ExtractResult = struct {
    /// Number of files successfully extracted.
    files_extracted: u32,
    /// Number of files that failed to extract.
    files_failed: u32,
    /// Total bytes written.
    bytes_written: u64,
};

/// Normalize a TRE entry path to a clean relative output path.
/// Strips the `..\..\DATA\` prefix (or similar) and converts backslashes to forward slashes.
/// Example: `..\..\DATA\AIDS\ATTITUDE.IFF` → `AIDS/ATTITUDE.IFF`
pub fn normalizeTrePath(path: []const u8) ?[]const u8 {
    // Find the DATA\ prefix and skip past it
    const data_marker = "DATA\\";
    if (std.mem.indexOf(u8, path, data_marker)) |idx| {
        return path[idx + data_marker.len ..];
    }
    // Also check with forward slashes
    const data_marker_fwd = "DATA/";
    if (std.mem.indexOf(u8, path, data_marker_fwd)) |idx| {
        return path[idx + data_marker_fwd.len ..];
    }
    // If no DATA prefix found, just strip leading dots and slashes
    var start: usize = 0;
    while (start < path.len and (path[start] == '.' or path[start] == '\\' or path[start] == '/')) {
        start += 1;
    }
    if (start >= path.len) return null;
    return path[start..];
}

/// Convert backslashes in a path to forward slashes, returning a newly allocated string.
pub fn toForwardSlashes(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, path.len);
    for (path, 0..) |c, i| {
        result[i] = if (c == '\\') '/' else c;
    }
    return result;
}

/// Extract the directory portion of a forward-slash path.
/// Returns null if there is no directory separator.
pub fn dirName(path: []const u8) ?[]const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return path[0..i];
    }
    return null;
}

/// Extract all files from a TRE archive to the given output directory.
/// `game_dat_data` should be the entire GAME.DAT file contents.
/// `output_dir` is the base directory to write extracted files to.
pub fn extractAll(
    allocator: std.mem.Allocator,
    game_dat_data: []const u8,
    output_dir: []const u8,
) !ExtractResult {
    // Parse ISO 9660 to find PRIV.TRE
    const pvd = iso9660.readPvd(game_dat_data) catch return ExtractError.TreNotFound;
    const tre_info = iso9660.findFile(allocator, game_dat_data, pvd, "PRIV.TRE") catch return ExtractError.TreNotFound;
    const tre_data = iso9660.readFileData(game_dat_data, tre_info.lba, tre_info.size) catch return ExtractError.TreNotFound;

    // Read all TRE entries
    const entries = try tre.readAllEntries(allocator, tre_data);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    var result = ExtractResult{
        .files_extracted = 0,
        .files_failed = 0,
        .bytes_written = 0,
    };

    // Extract each file
    for (entries) |entry| {
        const raw_path = normalizeTrePath(entry.path) orelse {
            result.files_failed += 1;
            continue;
        };

        // Convert backslashes to forward slashes for filesystem operations
        const clean_path = toForwardSlashes(allocator, raw_path) catch {
            result.files_failed += 1;
            continue;
        };
        defer allocator.free(clean_path);

        // Build full output path: output_dir/clean_path
        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, clean_path }) catch {
            result.files_failed += 1;
            continue;
        };
        defer allocator.free(full_path);

        // Create parent directories
        if (dirName(clean_path)) |rel_dir| {
            const dir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, rel_dir }) catch {
                result.files_failed += 1;
                continue;
            };
            defer allocator.free(dir_path);

            std.fs.cwd().makePath(dir_path) catch {
                result.files_failed += 1;
                continue;
            };
        }

        // Extract file data from TRE
        const file_data = tre.extractFileData(tre_data, entry.offset, entry.size) catch {
            result.files_failed += 1;
            continue;
        };

        // Write file to disk
        const file = std.fs.cwd().createFile(full_path, .{}) catch {
            result.files_failed += 1;
            continue;
        };
        defer file.close();

        file.writeAll(file_data) catch {
            result.files_failed += 1;
            continue;
        };

        result.files_extracted += 1;
        result.bytes_written += file_data.len;
    }

    return result;
}

// --- Tests ---

test "normalizeTrePath strips DATA prefix with backslashes" {
    const result = normalizeTrePath("..\\..\\DATA\\AIDS\\ATTITUDE.IFF");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("AIDS\\ATTITUDE.IFF", result.?);
}

test "normalizeTrePath strips DATA prefix with forward slashes" {
    const result = normalizeTrePath("../../DATA/APPEARNC/GALAXY.PAK");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("APPEARNC/GALAXY.PAK", result.?);
}

test "normalizeTrePath handles path without DATA prefix" {
    const result = normalizeTrePath("..\\..\\OTHER\\FILE.TXT");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("OTHER\\FILE.TXT", result.?);
}

test "normalizeTrePath returns null for empty-ish path" {
    const result = normalizeTrePath("..\\..");
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "normalizeTrePath handles just a filename after DATA" {
    const result = normalizeTrePath("..\\..\\DATA\\FILE.IFF");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("FILE.IFF", result.?);
}

test "toForwardSlashes converts backslashes" {
    const allocator = std.testing.allocator;
    const result = try toForwardSlashes(allocator, "AIDS\\ATTITUDE.IFF");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("AIDS/ATTITUDE.IFF", result);
}

test "toForwardSlashes preserves forward slashes" {
    const allocator = std.testing.allocator;
    const result = try toForwardSlashes(allocator, "AIDS/ATTITUDE.IFF");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("AIDS/ATTITUDE.IFF", result);
}

test "dirName extracts directory from path" {
    try std.testing.expectEqualStrings("AIDS", dirName("AIDS/ATTITUDE.IFF").?);
    try std.testing.expectEqualStrings("SPEECH/MID01", dirName("SPEECH/MID01/FILE.VOC").?);
    try std.testing.expectEqual(@as(?[]const u8, null), dirName("FILE.IFF"));
}

test "extractAll with fixture TRE data writes files to temp dir" {
    const allocator = std.testing.allocator;
    const testing_helpers = @import("testing.zig");

    // Load the test TRE fixture
    const tre_fixture = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(tre_fixture);

    // We need a mock GAME.DAT that contains the TRE data at the right ISO offset.
    // Since extractAll expects full ISO 9660 data, we'll test the individual components instead.
    // The extractAll function is an integration-level test; unit tests cover the components.

    // Verify the fixture has 3 entries with expected paths
    const header = try tre.readHeader(tre_fixture);
    try std.testing.expectEqual(@as(u32, 3), header.entry_count);

    const entries = try tre.readAllEntries(allocator, tre_fixture);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    // Verify path normalization works for all entries
    for (entries) |entry| {
        const normalized = normalizeTrePath(entry.path);
        try std.testing.expect(normalized != null);
    }
}

test "extraction pipeline: normalize, convert slashes, get dir for each TRE entry" {
    const allocator = std.testing.allocator;
    const testing_helpers = @import("testing.zig");

    const tre_fixture = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(tre_fixture);

    const entries = try tre.readAllEntries(allocator, tre_fixture);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    // Entry 0: ..\..\DATA\AIDS\ATTITUDE.IFF -> AIDS/ATTITUDE.IFF
    {
        const raw = normalizeTrePath(entries[0].path).?;
        const clean = try toForwardSlashes(allocator, raw);
        defer allocator.free(clean);
        try std.testing.expectEqualStrings("AIDS/ATTITUDE.IFF", clean);
        try std.testing.expectEqualStrings("AIDS", dirName(clean).?);
    }

    // Entry 1: ..\..\DATA\AIDS\BEHAVIOR.IFF -> AIDS/BEHAVIOR.IFF
    {
        const raw = normalizeTrePath(entries[1].path).?;
        const clean = try toForwardSlashes(allocator, raw);
        defer allocator.free(clean);
        try std.testing.expectEqualStrings("AIDS/BEHAVIOR.IFF", clean);
    }

    // Entry 2: ..\..\DATA\APPEARNC\GALAXY.PAK -> APPEARNC/GALAXY.PAK
    {
        const raw = normalizeTrePath(entries[2].path).?;
        const clean = try toForwardSlashes(allocator, raw);
        defer allocator.free(clean);
        try std.testing.expectEqualStrings("APPEARNC/GALAXY.PAK", clean);
        try std.testing.expectEqualStrings("APPEARNC", dirName(clean).?);
    }
}

test "extractAll writes files to temp directory" {
    // This test creates a minimal fake ISO 9660 + TRE structure and extracts to a temp dir.
    // We verify the correct number of files and their contents.
    const allocator = std.testing.allocator;

    // Build a minimal ISO 9660 image containing a small TRE archive.
    // PVD is at sector 16 (offset 32768), root dir at sector 17 (offset 34816).
    // PRIV.TRE file data starts at sector 18 (offset 36864).
    const sector_size = 2048;
    const pvd_sector = 16;
    const root_dir_sector = 17;
    const tre_sector = 18;

    // Our test TRE: 2 entries with tiny file data
    // Entry 0: ..\..\DATA\AIDS\TEST.IFF, offset=<toc_end>, size=4
    // Entry 1: ..\..\DATA\APPEARNC\TEST.PAK, offset=<toc_end+4>, size=5
    const entry_count: u32 = 2;
    const toc_size: u32 = tre.HEADER_SIZE + entry_count * tre.ENTRY_SIZE;
    const file0_data = "FORM";
    const file1_data = "HELLO";
    const tre_total_size = toc_size + file0_data.len + file1_data.len;

    // Build TRE data
    var tre_buf: [512]u8 = [_]u8{0} ** 512;
    // Header
    std.mem.writeInt(u32, tre_buf[0..4], entry_count, .little);
    std.mem.writeInt(u32, tre_buf[4..8], toc_size, .little);

    // Entry 0
    const e0_off = tre.HEADER_SIZE;
    tre_buf[e0_off] = 0x01; // flag
    const path0 = "..\\..\\DATA\\AIDS\\TEST.IFF";
    @memcpy(tre_buf[e0_off + 1 .. e0_off + 1 + path0.len], path0);
    std.mem.writeInt(u32, tre_buf[e0_off + 66 .. e0_off + 70], toc_size, .little); // offset
    std.mem.writeInt(u32, tre_buf[e0_off + 70 .. e0_off + 74], @intCast(file0_data.len), .little);

    // Entry 1
    const e1_off = e0_off + tre.ENTRY_SIZE;
    tre_buf[e1_off] = 0x01;
    const path1 = "..\\..\\DATA\\APPEARNC\\TEST.PAK";
    @memcpy(tre_buf[e1_off + 1 .. e1_off + 1 + path1.len], path1);
    std.mem.writeInt(u32, tre_buf[e1_off + 66 .. e1_off + 70], toc_size + @as(u32, @intCast(file0_data.len)), .little);
    std.mem.writeInt(u32, tre_buf[e1_off + 70 .. e1_off + 74], @intCast(file1_data.len), .little);

    // File data
    @memcpy(tre_buf[toc_size .. toc_size + file0_data.len], file0_data);
    @memcpy(tre_buf[toc_size + file0_data.len .. toc_size + file0_data.len + file1_data.len], file1_data);

    // Build a minimal ISO 9660 image
    const image_size = (tre_sector * sector_size) + tre_total_size;
    const iso_buf = try allocator.alloc(u8, image_size);
    defer allocator.free(iso_buf);
    @memset(iso_buf, 0);

    // PVD at sector 16
    const pvd_off = pvd_sector * sector_size;
    iso_buf[pvd_off + 0] = 1; // type = PVD
    @memcpy(iso_buf[pvd_off + 1 .. pvd_off + 6], "CD001");
    iso_buf[pvd_off + 6] = 1; // version
    // Volume space size (LE + BE) at offset 80
    std.mem.writeInt(u32, iso_buf[pvd_off + 80 .. pvd_off + 84], @intCast(image_size / sector_size), .little);
    // Block size (LE + BE) at offset 128
    std.mem.writeInt(u16, iso_buf[pvd_off + 128 .. pvd_off + 130], sector_size, .little);
    // Root directory record at offset 156
    const root_rec = iso_buf[pvd_off + 156 .. pvd_off + 156 + 34];
    root_rec[0] = 34; // record length
    std.mem.writeInt(u32, root_rec[2..6], root_dir_sector, .little); // extent LBA (LE)
    std.mem.writeInt(u32, root_rec[10..14], sector_size, .little); // data size (LE)
    root_rec[25] = 0x02; // flags: directory

    // Root directory at sector 17 - add a PRIV.TRE entry
    const dir_off = root_dir_sector * sector_size;
    // Skip . and .. entries (34 bytes each)
    const dot_rec = iso_buf[dir_off .. dir_off + 34];
    dot_rec[0] = 34;
    dot_rec[25] = 0x02;
    std.mem.writeInt(u32, dot_rec[2..6], root_dir_sector, .little);
    std.mem.writeInt(u32, dot_rec[10..14], sector_size, .little);
    dot_rec[32] = 1;
    dot_rec[33] = 0; // "."

    const dotdot_rec = iso_buf[dir_off + 34 .. dir_off + 68];
    dotdot_rec[0] = 34;
    dotdot_rec[25] = 0x02;
    std.mem.writeInt(u32, dotdot_rec[2..6], root_dir_sector, .little);
    std.mem.writeInt(u32, dotdot_rec[10..14], sector_size, .little);
    dotdot_rec[32] = 1;
    dotdot_rec[33] = 1; // ".."

    // PRIV.TRE entry
    const file_name = "PRIV.TRE;1";
    const rec_len: usize = 33 + file_name.len + (if (file_name.len % 2 == 0) 1 else 0);
    const tre_rec = iso_buf[dir_off + 68 .. dir_off + 68 + rec_len];
    tre_rec[0] = @intCast(rec_len); // record length
    std.mem.writeInt(u32, tre_rec[2..6], tre_sector, .little); // extent LBA
    std.mem.writeInt(u32, tre_rec[10..14], @intCast(tre_total_size), .little); // data size
    tre_rec[25] = 0x00; // flags: file
    tre_rec[32] = @intCast(file_name.len); // name length
    @memcpy(tre_rec[33 .. 33 + file_name.len], file_name);

    // Copy TRE data to the ISO image
    @memcpy(iso_buf[tre_sector * sector_size .. tre_sector * sector_size + tre_total_size], tre_buf[0..tre_total_size]);

    // Create a temp directory for extraction
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Run extraction
    const result = try extractAll(allocator, iso_buf, tmp_path);

    // Verify results
    try std.testing.expectEqual(@as(u32, 2), result.files_extracted);
    try std.testing.expectEqual(@as(u32, 0), result.files_failed);
    try std.testing.expectEqual(@as(u64, file0_data.len + file1_data.len), result.bytes_written);

    // Verify extracted files exist and have correct content
    {
        const f = try tmp_dir.dir.openFile("AIDS/TEST.IFF", .{});
        defer f.close();
        var buf: [64]u8 = undefined;
        const n = try f.readAll(&buf);
        try std.testing.expectEqualStrings("FORM", buf[0..n]);
    }
    {
        const f = try tmp_dir.dir.openFile("APPEARNC/TEST.PAK", .{});
        defer f.close();
        var buf: [64]u8 = undefined;
        const n = try f.readAll(&buf);
        try std.testing.expectEqualStrings("HELLO", buf[0..n]);
    }
}
