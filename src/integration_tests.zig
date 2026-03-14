//! Integration tests that run against real game data files.
//! These tests are skipped if the game data directory is not found.

const std = @import("std");
const iso9660 = @import("iso9660.zig");
const tre = @import("tre.zig");
const iff = @import("iff.zig");
const pal = @import("pal.zig");
const sprite = @import("sprite.zig");

/// Path to the original game data directory.
const GAME_DATA_DIR = "C:\\Program Files\\EA Games\\Wing Commander Privateer\\DATA";
const GAME_DAT_PATH = GAME_DATA_DIR ++ "\\GAME.DAT";

/// Load the entire GAME.DAT file into memory, or return null if not found.
fn loadGameDat(allocator: std.mem.Allocator) !?[]const u8 {
    const file = std.fs.openFileAbsolute(GAME_DAT_PATH, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    const bytes_read = try file.readAll(buf);
    if (bytes_read != stat.size) {
        allocator.free(buf);
        return null;
    }
    return buf;
}

test "integration: GAME.DAT PVD has CD001 signature" {
    const allocator = std.testing.allocator;
    const data = try loadGameDat(allocator) orelse return; // skip if no game data
    defer allocator.free(data);

    const pvd = try iso9660.readPvd(data);
    try std.testing.expectEqualStrings("CD001", &pvd.standard_id);
}

test "integration: GAME.DAT root directory contains PRIV.TRE" {
    const allocator = std.testing.allocator;
    const data = try loadGameDat(allocator) orelse return;
    defer allocator.free(data);

    const pvd = try iso9660.readPvd(data);
    const result = try iso9660.findFile(allocator, data, pvd, "PRIV.TRE");
    // PRIV.TRE should be at LBA 27 per the docs
    try std.testing.expectEqual(@as(u32, 27), result.lba);
    // PRIV.TRE size should be 89,486,108 bytes
    try std.testing.expectEqual(@as(u32, 89_486_108), result.size);
}

test "integration: PRIV.TRE has 832 entries" {
    const allocator = std.testing.allocator;
    const data = try loadGameDat(allocator) orelse return;
    defer allocator.free(data);

    const pvd = try iso9660.readPvd(data);
    const tre_info = try iso9660.findFile(allocator, data, pvd, "PRIV.TRE");
    const tre_data = try iso9660.readFileData(data, tre_info.lba, tre_info.size);

    const header = try tre.readHeader(tre_data);
    try std.testing.expectEqual(@as(u32, 832), header.entry_count);
    try std.testing.expectEqual(@as(u32, 86688), header.toc_size);
}

test "integration: PRIV.TRE entry 0 is ATTITUDE.IFF" {
    const allocator = std.testing.allocator;
    const data = try loadGameDat(allocator) orelse return;
    defer allocator.free(data);

    const pvd = try iso9660.readPvd(data);
    const tre_info = try iso9660.findFile(allocator, data, pvd, "PRIV.TRE");
    const tre_data = try iso9660.readFileData(data, tre_info.lba, tre_info.size);

    var entry = try tre.readEntry(allocator, tre_data, 0);
    defer entry.deinit();

    try std.testing.expectEqualStrings("..\\..\\DATA\\AIDS\\ATTITUDE.IFF", entry.path);
    try std.testing.expectEqual(@as(u32, 256), entry.size);
}

test "integration: PRIV.TRE first file starts with FORM" {
    const allocator = std.testing.allocator;
    const data = try loadGameDat(allocator) orelse return;
    defer allocator.free(data);

    const pvd = try iso9660.readPvd(data);
    const tre_info = try iso9660.findFile(allocator, data, pvd, "PRIV.TRE");
    const tre_data = try iso9660.readFileData(data, tre_info.lba, tre_info.size);

    var entry = try tre.readEntry(allocator, tre_data, 0);
    defer entry.deinit();

    const file_data = try tre.extractFileData(tre_data, entry.offset, entry.size);
    try std.testing.expectEqualStrings("FORM", file_data[0..4]);
}

test "integration: all 832 TRE files can be read" {
    const allocator = std.testing.allocator;
    const data = try loadGameDat(allocator) orelse return;
    defer allocator.free(data);

    const pvd = try iso9660.readPvd(data);
    const tre_info = try iso9660.findFile(allocator, data, pvd, "PRIV.TRE");
    const tre_data = try iso9660.readFileData(data, tre_info.lba, tre_info.size);

    const entries = try tre.readAllEntries(allocator, tre_data);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 832), entries.len);

    // Verify every file can be extracted without error
    for (entries) |e| {
        _ = try tre.extractFileData(tre_data, e.offset, e.size);
    }
}

test "integration: ATTITUDE.IFF parses as FORM with type ATTD" {
    const allocator = std.testing.allocator;
    const data = try loadGameDat(allocator) orelse return;
    defer allocator.free(data);

    const pvd = try iso9660.readPvd(data);
    const tre_info = try iso9660.findFile(allocator, data, pvd, "PRIV.TRE");
    const tre_data = try iso9660.readFileData(data, tre_info.lba, tre_info.size);

    var entry = try tre.readEntry(allocator, tre_data, 0);
    defer entry.deinit();

    const file_data = try tre.extractFileData(tre_data, entry.offset, entry.size);
    var chunk = try iff.parseFile(allocator, file_data);
    defer chunk.deinit();

    try std.testing.expectEqualStrings("FORM", &chunk.tag);
    try std.testing.expectEqualStrings("ATTD", &chunk.form_type.?);
    try std.testing.expectEqual(@as(u32, 248), chunk.size);
}

test "integration: parse every IFF file in the TRE without errors" {
    const allocator = std.testing.allocator;
    const data = try loadGameDat(allocator) orelse return;
    defer allocator.free(data);

    const pvd = try iso9660.readPvd(data);
    const tre_info = try iso9660.findFile(allocator, data, pvd, "PRIV.TRE");
    const tre_data = try iso9660.readFileData(data, tre_info.lba, tre_info.size);

    const entries = try tre.readAllEntries(allocator, tre_data);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    var iff_count: usize = 0;
    for (entries) |e| {
        // Check if this is an IFF file (starts with FORM, CAT, or LIST)
        const file_data = try tre.extractFileData(tre_data, e.offset, e.size);
        if (file_data.len < 8) continue;

        const tag = file_data[0..4];
        if (!std.mem.eql(u8, tag, "FORM") and
            !std.mem.eql(u8, tag, "CAT ") and
            !std.mem.eql(u8, tag, "LIST")) continue;

        var chunk = try iff.parseFile(allocator, file_data);
        defer chunk.deinit();

        try std.testing.expect(chunk.isContainer());
        iff_count += 1;
    }

    // We expect a significant number of IFF files (most of the 832 entries)
    try std.testing.expect(iff_count > 100);
}

// --- PAL palette integration tests ---

/// Helper to load TRE data from GAME.DAT.
fn loadTreData(allocator: std.mem.Allocator) !?struct { data: []const u8, tre_data: []const u8 } {
    const data = try loadGameDat(allocator) orelse return null;
    errdefer allocator.free(data);

    const pvd = try iso9660.readPvd(data);
    const tre_info = try iso9660.findFile(allocator, data, pvd, "PRIV.TRE");
    const tre_data = try iso9660.readFileData(data, tre_info.lba, tre_info.size);
    return .{ .data = data, .tre_data = tre_data };
}

test "integration: PCMAIN.PAL loads 256 RGB entries" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "PCMAIN.PAL");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    const palette = try pal.parse(file_data);

    // PCMAIN.PAL should have 256 entries; first entry should be black
    try std.testing.expectEqual(@as(u8, 0), palette.colors[0].r);
    try std.testing.expectEqual(@as(u8, 0), palette.colors[0].g);
    try std.testing.expectEqual(@as(u8, 0), palette.colors[0].b);
}

test "integration: SPACE.PAL first entry is black" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "SPACE.PAL");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    const palette = try pal.parse(file_data);

    // SPACE.PAL first entry should be black (0,0,0)
    try std.testing.expectEqual(@as(u8, 0), palette.colors[0].r);
    try std.testing.expectEqual(@as(u8, 0), palette.colors[0].g);
    try std.testing.expectEqual(@as(u8, 0), palette.colors[0].b);
}

test "integration: load all 4 palette files" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const pal_files = [_][]const u8{
        "PCMAIN.PAL",
        "PREFMAIN.PAL",
        "SPACE.PAL",
        "JOYCALIB.PAL",
    };

    for (pal_files) |filename| {
        var entry = try tre.findEntry(allocator, loaded.tre_data, filename);
        defer entry.deinit();

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        // Each PAL file should be at least 772 bytes and parse without error
        const palette = try pal.parse(file_data);
        // Basic sanity: all colors should have valid 8-bit values (guaranteed by parser)
        _ = palette;
    }
}

// --- Sprite RLE integration tests ---

/// Recursively find SHAP chunks in an IFF tree and attempt to decode them as sprites.
/// Returns the number of successfully decoded sprites.
fn countDecodableShapChunks(allocator: std.mem.Allocator, chunk: iff.Chunk) usize {
    var count: usize = 0;

    if (std.mem.eql(u8, &chunk.tag, "SHAP") and !chunk.isContainer()) {
        if (chunk.data.len >= sprite.HEADER_SIZE) {
            var s = sprite.decode(allocator, chunk.data) catch return 0;
            defer s.deinit();
            if (s.width > 0 and s.height > 0 and
                s.pixels.len == @as(usize, s.width) * @as(usize, s.height))
            {
                return 1;
            }
        }
    }

    for (chunk.children) |child| {
        count += countDecodableShapChunks(allocator, child);
    }
    return count;
}

test "integration: decode sprite from SHAP chunk in APPEARNC IFF" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const entries = try tre.readAllEntries(allocator, loaded.tre_data);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    // Find the first APPEARNC IFF file that contains decodable SHAP chunks
    var decoded_count: usize = 0;
    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".IFF")) continue;
        if (std.mem.indexOf(u8, e.path, "APPEARNC") == null) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < 8) continue;

        var chunk = iff.parseFile(allocator, file_data) catch continue;
        defer chunk.deinit();

        decoded_count += countDecodableShapChunks(allocator, chunk);
        if (decoded_count > 0) break;
    }

    // We expect to have decoded at least one sprite
    try std.testing.expect(decoded_count > 0);
}
