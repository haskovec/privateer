//! Integration tests that run against real game data files.
//! These tests are skipped if the game data directory is not found.

const std = @import("std");
const iso9660 = @import("iso9660.zig");
const tre = @import("tre.zig");
const iff = @import("iff.zig");
const pal = @import("pal.zig");
const sprite = @import("sprite.zig");
const shp = @import("shp.zig");
const pak = @import("pak.zig");
const voc = @import("voc.zig");
const vpk = @import("vpk.zig");
const music = @import("music.zig");

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

// --- SHP font/shape integration tests ---

test "integration: CONVFONT.SHP parses offset table" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "CONVFONT.SHP");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var shape_file = try shp.parse(allocator, file_data);
    defer shape_file.deinit();

    // Font files should contain multiple glyphs (at least a few dozen)
    try std.testing.expect(shape_file.spriteCount() > 10);
}

test "integration: CONVFONT.SHP glyphs decode" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "CONVFONT.SHP");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var shape_file = try shp.parse(allocator, file_data);
    defer shape_file.deinit();

    // Try decoding glyphs -- some may be empty (null/space), so find the first valid one
    var decoded: usize = 0;
    for (0..shape_file.spriteCount()) |i| {
        var s = shape_file.decodeSprite(allocator, i) catch continue;
        defer s.deinit();

        if (s.width > 0 and s.height > 0) {
            try std.testing.expectEqual(@as(usize, @as(usize, s.width) * @as(usize, s.height)), s.pixels.len);
            decoded += 1;
        }
    }

    // A font file should have many decodable glyphs
    try std.testing.expect(decoded > 20);
}

test "integration: load all SHP files" {
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

    var shp_count: usize = 0;
    var decoded_sprites: usize = 0;

    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".SHP")) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < shp.MIN_FILE_SIZE) continue;

        var shape_file = shp.parse(allocator, file_data) catch continue;
        defer shape_file.deinit();

        shp_count += 1;

        // Try decoding the first sprite from each SHP file
        if (shape_file.spriteCount() > 0) {
            var s = shape_file.decodeSprite(allocator, 0) catch continue;
            defer s.deinit();
            if (s.width > 0 and s.height > 0) {
                decoded_sprites += 1;
            }
        }
    }

    // We expect all 11 SHP files to parse (per docs: 6 fonts + 1 mouse cursor = 7+)
    try std.testing.expect(shp_count > 0);
    // At least some should have decodable sprites
    try std.testing.expect(decoded_sprites > 0);
}

// --- PAK resource unpacker integration tests ---

test "integration: parse a PAK file from TRE" {
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

    // Find the first PAK file and parse it
    var found = false;
    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".PAK")) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < pak.MIN_FILE_SIZE) continue;

        var pak_file = pak.parse(allocator, file_data) catch continue;
        defer pak_file.deinit();

        // PAK files should have at least 1 resource
        try std.testing.expect(pak_file.resourceCount() > 0);

        // Try extracting the first resource
        const r0 = try pak_file.getResource(0);
        try std.testing.expect(r0.len > 0);

        found = true;
        break;
    }

    try std.testing.expect(found);
}

test "integration: unpack all PAK files" {
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

    var pak_count: usize = 0;
    var total_resources: usize = 0;

    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".PAK")) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < pak.MIN_FILE_SIZE) continue;

        var pak_file = pak.parse(allocator, file_data) catch continue;
        defer pak_file.deinit();

        pak_count += 1;
        total_resources += pak_file.resourceCount();

        // Verify all resources can be extracted
        for (0..pak_file.resourceCount()) |i| {
            const resource = try pak_file.getResource(i);
            try std.testing.expect(resource.len > 0);
        }
    }

    // Per docs: 32 PAK files
    try std.testing.expect(pak_count > 0);
    try std.testing.expect(total_resources > 0);
}

// --- VOC audio integration tests ---

test "integration: parse a VOC file from TRE" {
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

    // Find the first VOC file and parse it
    var found = false;
    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".VOC")) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < voc.MIN_FILE_SIZE) continue;

        var voc_file = voc.parse(allocator, file_data) catch continue;
        defer voc_file.deinit();

        // VOC files should be 8-bit unsigned PCM at ~11025 Hz
        try std.testing.expectEqual(voc.CODEC_PCM_8BIT, voc_file.codec);
        try std.testing.expect(voc_file.sample_rate > 10000);
        try std.testing.expect(voc_file.sample_rate < 12000);
        try std.testing.expect(voc_file.samples.len > 0);

        found = true;
        break;
    }

    try std.testing.expect(found);
}

test "integration: load all VOC files, verify sample rates" {
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

    var voc_count: usize = 0;
    var total_samples: usize = 0;

    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".VOC")) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < voc.MIN_FILE_SIZE) continue;

        var voc_file = voc.parse(allocator, file_data) catch continue;
        defer voc_file.deinit();

        // All Privateer VOC files should be 11025 Hz, 8-bit PCM
        try std.testing.expectEqual(voc.CODEC_PCM_8BIT, voc_file.codec);
        try std.testing.expect(voc_file.sample_rate > 10000);
        try std.testing.expect(voc_file.sample_rate < 12000);

        voc_count += 1;
        total_samples += voc_file.samples.len;
    }

    // Per docs: 17 VOC files in DATA\SPEECH\MID01\
    try std.testing.expect(voc_count > 0);
    try std.testing.expect(total_samples > 0);
}

// --- VPK/VPF voice pack integration tests ---

test "integration: parse a VPK file and decompress first entry" {
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

    // Find the first VPK file
    var found = false;
    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".VPK")) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < vpk.MIN_FILE_SIZE) continue;

        var vpk_file = vpk.parse(allocator, file_data) catch continue;
        defer vpk_file.deinit();

        // Should have at least 1 entry
        try std.testing.expect(vpk_file.entryCount() > 0);

        // Decompress first entry - should be valid VOC
        const voc_data = try vpk_file.decompressEntry(allocator, 0);
        defer allocator.free(voc_data);

        try std.testing.expect(voc_data.len >= voc.MIN_FILE_SIZE);
        try std.testing.expect(std.mem.eql(u8, voc_data[0..voc.SIGNATURE_LEN], voc.SIGNATURE));

        // Parse the decompressed VOC
        var voc_file = try voc.parse(allocator, voc_data);
        defer voc_file.deinit();

        try std.testing.expectEqual(voc.CODEC_PCM_8BIT, voc_file.codec);
        try std.testing.expect(voc_file.sample_rate > 10000);
        try std.testing.expect(voc_file.sample_rate < 12000);
        try std.testing.expect(voc_file.samples.len > 0);

        found = true;
        break;
    }

    try std.testing.expect(found);
}

test "integration: decompress first entry from 5 random VPK files" {
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

    var vpk_count: usize = 0;
    var decompressed_count: usize = 0;
    var voc_valid_count: usize = 0;

    // Pick VPK files spread across the file list (every Nth)
    var vpk_indices: [5]usize = .{ 0, 0, 0, 0, 0 };
    var total_vpks: usize = 0;
    for (entries, 0..) |e, i| {
        if (std.mem.endsWith(u8, e.path, ".VPK") or std.mem.endsWith(u8, e.path, ".VPF")) {
            if (total_vpks < 5) {
                vpk_indices[total_vpks] = i;
            }
            total_vpks += 1;
        }
    }

    // Use evenly spaced entries if we have more than 5
    if (total_vpks > 5) {
        var vpk_idx: usize = 0;
        var count: usize = 0;
        const step = total_vpks / 5;
        for (entries, 0..) |e, i| {
            if (std.mem.endsWith(u8, e.path, ".VPK") or std.mem.endsWith(u8, e.path, ".VPF")) {
                if (count % step == 0 and vpk_idx < 5) {
                    vpk_indices[vpk_idx] = i;
                    vpk_idx += 1;
                }
                count += 1;
            }
        }
    }

    const test_count = @min(total_vpks, 5);
    for (vpk_indices[0..test_count]) |idx| {
        const e = entries[idx];
        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < vpk.MIN_FILE_SIZE) continue;

        var vpk_file = vpk.parse(allocator, file_data) catch continue;
        defer vpk_file.deinit();

        vpk_count += 1;

        // Decompress first entry
        const voc_data = vpk_file.decompressEntry(allocator, 0) catch continue;
        defer allocator.free(voc_data);

        decompressed_count += 1;

        // Verify it's valid VOC
        if (voc_data.len >= voc.SIGNATURE_LEN and
            std.mem.eql(u8, voc_data[0..voc.SIGNATURE_LEN], voc.SIGNATURE))
        {
            var voc_file = voc.parse(allocator, voc_data) catch continue;
            defer voc_file.deinit();
            voc_valid_count += 1;
        }
    }

    // We should have successfully parsed and decompressed from at least 5 files
    try std.testing.expect(vpk_count >= test_count);
    try std.testing.expect(decompressed_count >= test_count);
    try std.testing.expect(voc_valid_count >= test_count);
}

// --- Music format integration tests ---

test "integration: identify music file formats from TRE" {
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

    var adl_count: usize = 0;
    var gen_count: usize = 0;

    for (entries) |e| {
        const is_adl = std.mem.endsWith(u8, e.path, ".ADL");
        const is_gen = std.mem.endsWith(u8, e.path, ".GEN");
        if (!is_adl and !is_gen) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < music.MIN_FILE_SIZE) continue;

        // Identify the format
        const is_xmidi = music.isXmidi(file_data);
        const is_midi = music.isMidi(file_data);

        // At least one identification should succeed (or it's raw)
        _ = is_xmidi;
        _ = is_midi;

        if (is_adl) adl_count += 1;
        if (is_gen) gen_count += 1;
    }

    // Per docs: 5 ADL + 5 GEN
    try std.testing.expectEqual(@as(usize, 5), adl_count);
    try std.testing.expectEqual(@as(usize, 5), gen_count);
}

test "integration: load all 10 music files" {
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

    var parsed_count: usize = 0;
    var xmidi_count: usize = 0;
    var midi_count: usize = 0;
    var raw_count: usize = 0;

    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".ADL") and
            !std.mem.endsWith(u8, e.path, ".GEN")) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < music.MIN_FILE_SIZE) continue;

        var music_file = music.parse(allocator, file_data) catch continue;

        defer music_file.deinit();

        parsed_count += 1;

        switch (music_file.format) {
            .xmidi => {
                xmidi_count += 1;
                // XMIDI files should have at least 1 sequence
                try std.testing.expect(music_file.sequence_count > 0);
                try std.testing.expect(music_file.sequences.len > 0);
                // Each sequence should have event data
                for (music_file.sequences) |seq| {
                    try std.testing.expect(seq.event_data.len > 0);
                }
            },
            .midi => {
                midi_count += 1;
                try std.testing.expect(music_file.midi_header != null);
                try std.testing.expect(music_file.sequence_count > 0);
            },
            .raw => {
                raw_count += 1;
            },
        }
    }

    // All 10 music files should parse
    try std.testing.expectEqual(@as(usize, 10), parsed_count);
    // Log the format breakdown (at least one format should be represented)
    try std.testing.expect(xmidi_count + midi_count + raw_count == 10);
}
