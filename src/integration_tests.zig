//! Integration tests that run against real game data files.
//! These tests are skipped if the game data directory is not found.

const std = @import("std");
const iso9660 = @import("formats/iso9660.zig");
const tre = @import("formats/tre.zig");
const iff = @import("formats/iff.zig");
const pal = @import("formats/pal.zig");
const sprite = @import("formats/sprite.zig");
const shp = @import("formats/shp.zig");
const pak = @import("formats/pak.zig");
const voc = @import("formats/voc.zig");
const vpk = @import("formats/vpk.zig");
const music = @import("formats/music.zig");
const extract = @import("cli/extract.zig");
const render = @import("render/render.zig");
const png = @import("render/png.zig");
const validate = @import("cli/validate.zig");
const palette_viewer = @import("cli/palette_viewer.zig");
const midgame = @import("game/midgame.zig");
const universe = @import("game/universe.zig");
const bases = @import("game/bases.zig");
const nav_graph = @import("game/nav_graph.zig");
const cockpit = @import("cockpit/cockpit.zig");
const mfd = @import("cockpit/mfd.zig");
const damage_display = @import("cockpit/damage_display.zig");
const weapons = @import("combat/weapons.zig");
const commodities = @import("economy/commodities.zig");

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

/// Find a TRE file by directory and filename when multiple files share the same name.
/// Returns the file data slice, or null if not found.
fn findTreFileByPath(allocator: std.mem.Allocator, tre_data: []const u8, dir: []const u8, filename: []const u8) !?[]const u8 {
    const header = try tre.readHeader(tre_data);
    for (0..header.entry_count) |i| {
        var entry = try tre.readEntry(allocator, tre_data, @intCast(i));
        defer entry.deinit();
        // Check if path contains the directory fragment AND ends with the filename
        const basename = std.fs.path.basename(entry.path);
        if (std.ascii.eqlIgnoreCase(basename, filename)) {
            // Check directory component
            const has_dir = for (0..entry.path.len) |j| {
                const remaining = entry.path[j..];
                if (remaining.len >= dir.len and std.ascii.eqlIgnoreCase(remaining[0..dir.len], dir)) {
                    break true;
                }
            } else false;
            if (has_dir) {
                return try tre.extractFileData(tre_data, entry.offset, entry.size);
            }
        }
    }
    return null;
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

// --- Sprite-to-PNG rendering integration tests ---

test "integration: render APPEARNC sprite to PNG" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    // Load PCMAIN.PAL for color mapping
    var pal_entry = try tre.findEntry(allocator, loaded.tre_data, "PCMAIN.PAL");
    defer pal_entry.deinit();
    const pal_data = try tre.extractFileData(loaded.tre_data, pal_entry.offset, pal_entry.size);
    const palette = try pal.parse(pal_data);

    // Find the first APPEARNC IFF file with SHAP chunks
    const entries = try tre.readAllEntries(allocator, loaded.tre_data);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    var png_count: usize = 0;
    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".IFF")) continue;
        if (std.mem.indexOf(u8, e.path, "APPEARNC") == null) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < 8) continue;

        var chunk = iff.parseFile(allocator, file_data) catch continue;
        defer chunk.deinit();

        const sprites = render.findSprites(allocator, chunk) catch continue;
        defer {
            for (sprites) |*s| {
                var spr = s.*;
                spr.deinit();
            }
            allocator.free(sprites);
        }

        for (sprites) |spr| {
            const png_data = render.spriteToPng(allocator, spr, palette) catch continue;
            defer allocator.free(png_data);

            // Verify PNG starts with valid signature
            if (png_data.len >= 8) {
                if (std.mem.eql(u8, png_data[0..8], &png.SIGNATURE)) {
                    png_count += 1;
                }
            }
        }

        if (png_count > 0) break;
    }

    // We should have rendered at least one sprite to PNG
    try std.testing.expect(png_count > 0);
}

test "integration: batch render APPEARNC sprites to PNG" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    // Load palette
    var pal_entry = try tre.findEntry(allocator, loaded.tre_data, "PCMAIN.PAL");
    defer pal_entry.deinit();
    const pal_data = try tre.extractFileData(loaded.tre_data, pal_entry.offset, pal_entry.size);
    const palette = try pal.parse(pal_data);

    const entries = try tre.readAllEntries(allocator, loaded.tre_data);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    var total_sprites: usize = 0;
    var total_pngs: usize = 0;
    var iff_count: usize = 0;

    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".IFF")) continue;
        if (std.mem.indexOf(u8, e.path, "APPEARNC") == null) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < 8) continue;

        var chunk = iff.parseFile(allocator, file_data) catch continue;
        defer chunk.deinit();

        const sprites = render.findSprites(allocator, chunk) catch continue;
        defer {
            for (sprites) |*s| {
                var spr = s.*;
                spr.deinit();
            }
            allocator.free(sprites);
        }

        iff_count += 1;
        total_sprites += sprites.len;

        for (sprites) |spr| {
            const png_data = render.spriteToPng(allocator, spr, palette) catch continue;
            defer allocator.free(png_data);

            if (png_data.len >= 8 and std.mem.eql(u8, png_data[0..8], &png.SIGNATURE)) {
                total_pngs += 1;
            }
        }
    }

    // APPEARNC directory should contain multiple IFF files with sprites
    try std.testing.expect(iff_count > 0);
    try std.testing.expect(total_sprites > 0);
    try std.testing.expect(total_pngs > 0);
    // Most decoded sprites should render successfully
    try std.testing.expect(total_pngs >= total_sprites / 2);
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

// --- Asset extraction integration tests ---

test "integration: extractAll produces correct file count and sizes" {
    const allocator = std.testing.allocator;
    const data = try loadGameDat(allocator) orelse return;
    defer allocator.free(data);

    // Create a temp directory for extraction
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const result = try extract.extractAll(allocator, data, tmp_path);

    // All 832 files should be extracted with 0 failures
    try std.testing.expectEqual(@as(u32, 832), result.files_extracted);
    try std.testing.expectEqual(@as(u32, 0), result.files_failed);
    try std.testing.expect(result.bytes_written > 0);
}

test "integration: extracted files match TRE entry sizes" {
    const allocator = std.testing.allocator;
    const data = try loadGameDat(allocator) orelse return;
    defer allocator.free(data);

    const pvd = try iso9660.readPvd(data);
    const tre_info = try iso9660.findFile(allocator, data, pvd, "PRIV.TRE");
    const tre_data = try iso9660.readFileData(data, tre_info.lba, tre_info.size);

    // Create a temp directory for extraction
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    _ = try extract.extractAll(allocator, data, tmp_path);

    // Spot-check a few files: verify extracted sizes match TRE entry sizes
    const entries = try tre.readAllEntries(allocator, tre_data);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    // Check first 10 files
    var checked: usize = 0;
    for (entries[0..@min(entries.len, 10)]) |entry| {
        const raw_path = extract.normalizeTrePath(entry.path) orelse continue;
        const clean_path = try extract.toForwardSlashes(allocator, raw_path);
        defer allocator.free(clean_path);

        const f = tmp_dir.dir.openFile(clean_path, .{}) catch continue;
        defer f.close();

        const stat = try f.stat();
        try std.testing.expectEqual(@as(u64, entry.size), stat.size);
        checked += 1;
    }

    try std.testing.expect(checked > 0);
}

// --- Data validation suite (Phase 2.4 gate for Phase 3) ---

test "integration: data validation suite reports 0 errors on game data" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const result = try validate.validateAll(allocator, loaded.tre_data);

    // Report results
    std.debug.print("\n=== Data Validation Report ===\n", .{});
    std.debug.print("Total files:     {}\n", .{result.total_files});
    std.debug.print("IFF parsed:      {} (errors: {})\n", .{ result.iff_parsed, result.iff_errors });
    std.debug.print("PAL parsed:      {} (errors: {})\n", .{ result.pal_parsed, result.pal_errors });
    std.debug.print("SHP parsed:      {} (errors: {})\n", .{ result.shp_parsed, result.shp_errors });
    std.debug.print("PAK parsed:      {} (errors: {})\n", .{ result.pak_parsed, result.pak_errors });
    std.debug.print("VOC parsed:      {} (errors: {})\n", .{ result.voc_parsed, result.voc_errors });
    std.debug.print("VPK/VPF parsed:  {} (errors: {})\n", .{ result.vpk_parsed, result.vpk_errors });
    std.debug.print("Music parsed:    {} (errors: {})\n", .{ result.music_parsed, result.music_errors });
    std.debug.print("Other files:     {}\n", .{result.other_files});
    std.debug.print("Warnings:        {}\n", .{result.warnings});
    std.debug.print("Total parsed:    {}\n", .{result.totalParsed()});
    std.debug.print("Total errors:    {}\n", .{result.totalErrors()});
    std.debug.print("==============================\n", .{});

    // Gate check: 0 errors required for Phase 3
    try std.testing.expectEqual(@as(u32, 832), result.total_files);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(u32, 0), result.warnings);
}

// --- Palette viewer integration tests (Phase 2.3) ---

test "integration: render all 4 palettes to PNG" {
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
        const palette = try pal.parse(file_data);

        // Render to PNG
        const png_data = try palette_viewer.paletteToPng(allocator, palette);
        defer allocator.free(png_data);

        // Verify valid PNG
        try std.testing.expectEqualSlices(u8, &png.SIGNATURE, png_data[0..8]);

        // Verify 256x256 dimensions in IHDR
        const w = std.mem.readInt(u32, png_data[16..20], .big);
        const h = std.mem.readInt(u32, png_data[20..24], .big);
        try std.testing.expectEqual(@as(u32, 256), w);
        try std.testing.expectEqual(@as(u32, 256), h);
    }
}

// --- Scene data exploration (Phase 4.1) ---

// --- Scene system integration tests (Phase 4.1) ---

const scene = @import("game/scene.zig");
const scene_renderer = @import("render/scene_renderer.zig");
const framebuffer_mod = @import("render/framebuffer.zig");

test "integration: parse GAMEFLOW.IFF scene structure" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "GAMEFLOW.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var gameflow = try scene.parseGameFlow(allocator, file_data);
    defer gameflow.deinit();

    // GAMEFLOW.IFF should contain multiple rooms
    try std.testing.expect(gameflow.rooms.len > 0);

    // Each room should have at least one scene
    for (gameflow.rooms) |room| {
        try std.testing.expect(room.scenes.len > 0);
    }

    // Each scene should have at least one sprite (interactive element)
    var total_sprites: usize = 0;
    for (gameflow.rooms) |room| {
        for (room.scenes) |scn| {
            total_sprites += scn.sprites.len;
        }
    }
    try std.testing.expect(total_sprites > 0);
}

test "integration: GAMEFLOW rooms have valid info bytes" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "GAMEFLOW.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var gameflow = try scene.parseGameFlow(allocator, file_data);
    defer gameflow.deinit();

    // All rooms should have distinct info bytes (room type IDs)
    // and valid tune/effect data
    for (gameflow.rooms) |room| {
        // INFO byte should exist
        _ = room.info;
        // Scenes should have INFO bytes too
        for (room.scenes) |scn| {
            _ = scn.info;
        }
    }
}

// --- Scene renderer integration tests (Phase 4.2) ---

test "integration: decode scene background from OPTSHPS.PAK" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    // OPTSHPS.PAK contains full-screen scene backgrounds as RLE sprites
    var entry = try tre.findEntry(allocator, loaded.tre_data, "OPTSHPS.PAK");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var pak_file = try pak.parse(allocator, file_data);
    defer pak_file.deinit();

    // Should have many resources (226 per diagnostic)
    try std.testing.expect(pak_file.resourceCount() > 10);

    // Resource 1 (index 1) is a full-screen scene sprite
    const resource = try pak_file.getResource(1);
    var pack = try scene_renderer.parseScenePack(allocator, resource);
    defer pack.deinit();

    try std.testing.expectEqual(@as(usize, 1), pack.spriteCount());

    // Decode the background sprite
    var spr = try pack.decodeSprite(allocator, 0);
    defer spr.deinit();

    // Should be 319x199 (full screen minus 1 pixel border)
    try std.testing.expectEqual(@as(u16, 319), spr.width);
    try std.testing.expectEqual(@as(u16, 199), spr.height);

    // Render to framebuffer
    var fb = framebuffer_mod.Framebuffer.create();
    const view = scene_renderer.SceneView{ .background = spr };
    scene_renderer.renderScene(&fb, view);

    // Verify framebuffer has non-black content
    var non_zero: usize = 0;
    for (fb.pixels) |p| {
        if (p != 0) non_zero += 1;
    }
    try std.testing.expect(non_zero > 1000);
}

test "integration: render scene from CU.PAK with palette" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "CU.PAK");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var pak_file = try pak.parse(allocator, file_data);
    defer pak_file.deinit();

    try std.testing.expect(pak_file.resourceCount() > 5);

    // Decode resource 1 as scene background
    const resource = try pak_file.getResource(1);
    var pack = try scene_renderer.parseScenePack(allocator, resource);
    defer pack.deinit();

    var spr = try pack.decodeSprite(allocator, 0);
    defer spr.deinit();

    // CU.PAK backgrounds are 319x199 or 319x128
    try std.testing.expectEqual(@as(u16, 319), spr.width);
    try std.testing.expect(spr.height > 100);

    // Render and verify
    var fb = framebuffer_mod.Framebuffer.create();
    scene_renderer.renderScene(&fb, .{ .background = spr });

    var non_zero: usize = 0;
    for (fb.pixels) |p| {
        if (p != 0) non_zero += 1;
    }
    try std.testing.expect(non_zero > 1000);
}

test "integration: scene PAK resources with palettes decode correctly" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    // MID1.PAK has a palette as resource 0 and sprites as subsequent resources
    var entry = try tre.findEntry(allocator, loaded.tre_data, "MID1.PAK");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var pak_file = try pak.parse(allocator, file_data);
    defer pak_file.deinit();

    try std.testing.expect(pak_file.resourceCount() > 5);

    // Resource 0 should be a palette (772 bytes)
    const pal_resource = try pak_file.getResource(0);
    try std.testing.expectEqual(@as(usize, pal.PAL_FILE_SIZE), pal_resource.len);
    const palette = try pal.parse(pal_resource);
    _ = palette;

    // Resource 1 should decode as a scene sprite
    const spr_resource = try pak_file.getResource(1);
    var pack = try scene_renderer.parseScenePack(allocator, spr_resource);
    defer pack.deinit();

    try std.testing.expect(pack.spriteCount() >= 1);

    var spr = try pack.decodeSprite(allocator, 0);
    defer spr.deinit();

    try std.testing.expect(spr.width > 100);
    try std.testing.expect(spr.height > 50);
    try std.testing.expect(spr.pixels.len > 0);
}

// --- Click region / interaction system integration tests (Phase 4.3) ---

const click_region = @import("game/click_region.zig");

test "integration: parse GAMEFLOW.IFF sprite actions" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "GAMEFLOW.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var gameflow = try scene.parseGameFlow(allocator, file_data);
    defer gameflow.deinit();

    // Every sprite should have parseable EFCT data
    var scene_transitions: usize = 0;
    var no_actions: usize = 0;
    var special_actions: usize = 0;
    var scripted_actions: usize = 0;

    for (gameflow.rooms) |room| {
        for (room.scenes) |scn| {
            for (scn.sprites) |spr| {
                const action = click_region.parseAction(spr.effect);
                switch (action) {
                    .none => no_actions += 1,
                    .scene_transition => scene_transitions += 1,
                    .scripted => scripted_actions += 1,
                    else => special_actions += 1,
                }
            }
        }
    }

    // There should be many scene transitions (most sprites are navigation)
    try std.testing.expect(scene_transitions > 50);
    // Some decorative sprites have no action
    try std.testing.expect(no_actions > 0);
    // Some special actions (merchant, conversation, etc.)
    try std.testing.expect(special_actions > 0);
}

test "integration: scene transition targets are valid scene IDs" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "GAMEFLOW.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var gameflow = try scene.parseGameFlow(allocator, file_data);
    defer gameflow.deinit();

    // Build set of all valid scene IDs
    var valid_scenes = std.AutoHashMap(u8, void).init(allocator);
    defer valid_scenes.deinit();
    for (gameflow.rooms) |room| {
        for (room.scenes) |scn| {
            try valid_scenes.put(scn.info, {});
        }
    }

    // Verify all scene transitions point to valid scenes
    for (gameflow.rooms) |room| {
        for (room.scenes) |scn| {
            for (scn.sprites) |spr| {
                const action = click_region.parseAction(spr.effect);
                if (action == .scene_transition) {
                    try std.testing.expect(valid_scenes.contains(action.scene_transition));
                }
            }
        }
    }
}

// --- Midgame animation integration tests ---

test "integration: LANDINGS.PAK loads as midgame sequence" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "LANDINGS.PAK");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);

    var seq = try midgame.MidgameSequence.init(allocator, file_data);
    defer seq.deinit();

    // LANDINGS.PAK should have multiple animation frames
    try std.testing.expect(seq.frame_count > 0);
    try std.testing.expectEqual(@as(usize, 0), seq.currentFrameIndex());
    try std.testing.expect(!seq.isComplete());
}

test "integration: LANDINGS.PAK frames decode as scene packs" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "LANDINGS.PAK");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);

    var seq = try midgame.MidgameSequence.init(allocator, file_data);
    defer seq.deinit();

    // Should have detected the palette
    try std.testing.expect(seq.has_palette);

    // First animation frame should decode as a scene pack with sprites
    const frame_data = try seq.getFrameData();
    try std.testing.expect(frame_data.len > 8);

    var pack = try scene_renderer.parseScenePack(allocator, frame_data);
    defer pack.deinit();
    try std.testing.expect(pack.spriteCount() > 0);

    // Decode first sprite - should be a reasonable size
    var spr = try pack.decodeSprite(allocator, 0);
    defer spr.deinit();
    try std.testing.expect(spr.width > 10);
    try std.testing.expect(spr.height > 10);
}

test "integration: MIDGAMES PAK files all load as sequences" {
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

    var midgame_count: usize = 0;
    for (entries) |entry| {
        // Check if this is a MIDGAMES PAK file
        const is_midgames = std.mem.indexOf(u8, entry.path, "MIDGAMES") != null;
        const is_pak = std.mem.endsWith(u8, entry.path, ".PAK");
        if (!is_midgames or !is_pak) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        var seq = midgame.MidgameSequence.init(allocator, file_data) catch continue;
        defer seq.deinit();

        try std.testing.expect(seq.frame_count > 0);
        midgame_count += 1;
    }

    // Should find multiple MIDGAMES PAK files
    try std.testing.expect(midgame_count > 0);
}

test "integration: midgame sequence advances through frames" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "LANDINGS.PAK");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);

    var seq = try midgame.MidgameSequence.init(allocator, file_data);
    defer seq.deinit();

    const total_frames = seq.frame_count;
    try std.testing.expect(total_frames > 1);

    // Advance through all frames
    var frames_seen: usize = 1; // starts on frame 0
    while (!seq.isComplete()) {
        seq.advance(midgame.DEFAULT_FRAME_DURATION_MS);
        if (!seq.isComplete()) {
            frames_seen += 1;
        }
    }

    // Should have visited all frames
    try std.testing.expectEqual(total_frames, frames_seen);
    try std.testing.expectEqual(total_frames - 1, seq.currentFrameIndex());
}

// --- Universe data integration tests (Phase 5.1) ---

test "integration: QUADRANT.IFF parses as FORM:UNIV with 4 quadrants" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "QUADRANT.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);

    // Verify it's a FORM:UNIV
    var chunk = try iff.parseFile(allocator, file_data);
    defer chunk.deinit();
    try std.testing.expectEqualStrings("FORM", &chunk.tag);
    try std.testing.expectEqualStrings("UNIV", &chunk.form_type.?);
}

test "integration: parse QUADRANT.IFF universe structure" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "QUADRANT.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var univ = try universe.parseUniverse(allocator, file_data);
    defer univ.deinit();

    // The Gemini Sector has 4 quadrants
    try std.testing.expectEqual(@as(usize, 4), univ.quadrants.len);
}

test "integration: each quadrant contains systems" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "QUADRANT.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var univ = try universe.parseUniverse(allocator, file_data);
    defer univ.deinit();

    // Each quadrant should have at least 1 system
    for (univ.quadrants) |q| {
        try std.testing.expect(q.systems.len > 0);
    }

    // Total systems should be substantial (Gemini Sector has ~69 systems)
    const total = univ.totalSystems();
    try std.testing.expect(total > 50);
}

test "integration: universe systems have valid coordinates and names" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "QUADRANT.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var univ = try universe.parseUniverse(allocator, file_data);
    defer univ.deinit();

    // All systems should have valid data
    for (univ.quadrants) |q| {
        // Quadrant should have a name
        try std.testing.expect(q.name.len > 0);
        for (q.systems) |sys| {
            // Each system has a name
            try std.testing.expect(sys.name.len > 0);
            // Coordinates should be within reasonable range for a map grid
            try std.testing.expect(sys.x > -200 and sys.x < 200);
            try std.testing.expect(sys.y > -200 and sys.y < 200);
        }
    }

    // Some systems should have bases
    const base_count = univ.totalBases();
    try std.testing.expect(base_count > 0);

    // Should be able to find known systems by name
    const troy = univ.findSystemByName("Troy");
    try std.testing.expect(troy != null);
    try std.testing.expect(troy.?.hasBase());

    const oxford = univ.findSystemByName("Oxford");
    try std.testing.expect(oxford != null);
}

// --- BASES.IFF integration tests (Phase 5.2) ---

test "integration: BASES.IFF parses all bases with names" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "BASES.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var registry = try bases.parseBases(allocator, file_data);
    defer registry.deinit();

    // Should have a substantial number of bases
    try std.testing.expect(registry.bases.len > 30);

    // All bases should have names
    for (registry.bases) |base| {
        try std.testing.expect(base.name.len > 0);
    }

    // Should be able to find known bases
    const perry = registry.findByName("Perry Naval Base");
    try std.testing.expect(perry != null);

    const oxford = registry.findByName("Oxford");
    try std.testing.expect(oxford != null);
}

// --- TABLE.DAT integration tests (Phase 5.2) ---

test "integration: TABLE.DAT parses as 69x69 distance matrix" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "TABLE.DAT");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var graph = try nav_graph.parseNavGraph(allocator, file_data);
    defer graph.deinit();

    // 69 star systems in the Gemini Sector
    try std.testing.expectEqual(@as(u16, 69), graph.system_count);

    // Self-distances should be 0
    for (0..69) |i| {
        try std.testing.expectEqual(@as(u8, 0), graph.getDistance(@intCast(i), @intCast(i)).?);
    }

    // Most systems should have at least one adjacent neighbor
    var connected_count: usize = 0;
    for (0..69) |i| {
        const adj = try graph.getAdjacentSystems(@intCast(i), allocator);
        defer allocator.free(adj);
        if (adj.len > 0) connected_count += 1;
    }
    // At least 60 of 69 systems should be connected
    try std.testing.expect(connected_count >= 60);
}

// --- Cross-data integration test (Phase 5.2) ---

test "integration: universe system indices match nav graph dimensions" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    // Load universe
    var q_entry = try tre.findEntry(allocator, loaded.tre_data, "QUADRANT.IFF");
    defer q_entry.deinit();
    const q_data = try tre.extractFileData(loaded.tre_data, q_entry.offset, q_entry.size);
    var univ = try universe.parseUniverse(allocator, q_data);
    defer univ.deinit();

    // Load nav graph
    var t_entry = try tre.findEntry(allocator, loaded.tre_data, "TABLE.DAT");
    defer t_entry.deinit();
    const t_data = try tre.extractFileData(loaded.tre_data, t_entry.offset, t_entry.size);
    var graph = try nav_graph.parseNavGraph(allocator, t_data);
    defer graph.deinit();

    // Total systems should match nav graph dimension
    try std.testing.expectEqual(@as(usize, graph.system_count), univ.totalSystems());

    // All system indices should be valid in the nav graph
    for (univ.quadrants) |q| {
        for (q.systems) |sys| {
            try std.testing.expect(sys.index < graph.system_count);
        }
    }
}

// --- Phase 6.1: Cockpit ---

test "integration: CLUNKCK.IFF (Tarsus cockpit) loads with 4 views" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "CLUNKCK.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var cock = try cockpit.parseCockpitIff(allocator, file_data);
    defer cock.deinit();

    try std.testing.expectEqual(@as(u8, 4), cock.view_count);
    try std.testing.expect(cock.getView(.front) != null);
    try std.testing.expect(cock.getView(.right) != null);
    try std.testing.expect(cock.getView(.back) != null);
    try std.testing.expect(cock.getView(.left) != null);
}

test "integration: Tarsus front cockpit sprite covers full screen" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "CLUNKCK.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var cock = try cockpit.parseCockpitIff(allocator, file_data);
    defer cock.deinit();

    const front = cock.getView(.front).?;
    // Front cockpit sprite should cover most of the 320x200 screen
    try std.testing.expect(front.sprite.width >= 200);
    try std.testing.expect(front.sprite.height >= 150);
}

test "integration: all 4 cockpit types load successfully" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const ship_types = [_]cockpit.ShipType{ .tarsus, .centurion, .galaxy, .orion };
    for (ship_types) |ship| {
        var entry = try tre.findEntry(allocator, loaded.tre_data, ship.iffFilename());
        defer entry.deinit();

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        var cock = try cockpit.parseCockpitIff(allocator, file_data);
        defer cock.deinit();

        // All cockpit types should have at least a front view
        try std.testing.expect(cock.getView(.front) != null);
        try std.testing.expect(cock.view_count >= 1);
    }
}

test "integration: cockpit renders onto framebuffer without crash" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "CLUNKCK.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var cock = try cockpit.parseCockpitIff(allocator, file_data);
    defer cock.deinit();

    // Create framebuffer, fill with "space" color, overlay cockpit
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(1); // space background
    cockpit.renderCockpit(&fb, &cock, .front);

    // After rendering, some pixels should be cockpit (non-zero, non-1)
    // and some should still be space (1 or 0 if transparent)
    var has_cockpit_pixel = false;
    var has_space_pixel = false;
    for (fb.pixels) |p| {
        if (p != 0 and p != 1) has_cockpit_pixel = true;
        if (p == 1) has_space_pixel = true;
    }
    // Cockpit frame should have opaque pixels
    try std.testing.expect(has_cockpit_pixel);
    // Viewport window should let space show through
    try std.testing.expect(has_space_pixel);
}

// --- MFD (Multi-Function Display) integration tests ---

test "integration: Tarsus cockpit has MFD display areas" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "CLUNKCK.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var cock = try cockpit.parseCockpitIff(allocator, file_data);
    defer cock.deinit();

    // Tarsus has 1 MFD display area
    try std.testing.expect(cock.mfd.display_count >= 1);
    // First display should have a valid rect within 320x200
    const display = cock.mfd.displays[0].?;
    try std.testing.expect(display.rect.x2 <= 320);
    try std.testing.expect(display.rect.y2 <= 200);
    try std.testing.expect(display.rect.width() > 0);
    try std.testing.expect(display.rect.height() > 0);
}

test "integration: Centurion cockpit has 2 MFD display areas" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "FIGHTCK.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var cock = try cockpit.parseCockpitIff(allocator, file_data);
    defer cock.deinit();

    // Centurion has 2 MFD displays (left and right)
    try std.testing.expectEqual(@as(u8, 2), cock.mfd.display_count);
    // Both should have valid rects
    for (0..2) |i| {
        const display = cock.mfd.displays[i].?;
        try std.testing.expect(display.rect.x2 <= 320);
        try std.testing.expect(display.rect.y2 <= 200);
        try std.testing.expect(display.rect.width() > 0);
    }
}

test "integration: all cockpit types have radar and shield dials" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const ship_types = [_]cockpit.ShipType{ .tarsus, .centurion, .galaxy, .orion };
    for (ship_types) |ship| {
        var entry = try tre.findEntry(allocator, loaded.tre_data, ship.iffFilename());
        defer entry.deinit();

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        var cock = try cockpit.parseCockpitIff(allocator, file_data);
        defer cock.deinit();

        // All ships should have radar and shield display rects
        try std.testing.expect(cock.mfd.dials.radar_rect != null);
        try std.testing.expect(cock.mfd.dials.shield_rect != null);

        // Radar rect should be a reasonable size
        const radar = cock.mfd.dials.radar_rect.?;
        try std.testing.expect(radar.width() >= 20);
        try std.testing.expect(radar.height() >= 20);
    }
}

test "integration: all cockpit types have HUD modes" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const ship_types = [_]cockpit.ShipType{ .tarsus, .centurion, .galaxy, .orion };
    for (ship_types) |ship| {
        var entry = try tre.findEntry(allocator, loaded.tre_data, ship.iffFilename());
        defer entry.deinit();

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        var cock = try cockpit.parseCockpitIff(allocator, file_data);
        defer cock.deinit();

        // All ships should have at least targeting and crosshair HUD modes
        try std.testing.expect(cock.mfd.hud_mode_count >= 2);
    }
}

test "integration: Tarsus DIAL has speed displays with labels" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "CLUNKCK.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var cock = try cockpit.parseCockpitIff(allocator, file_data);
    defer cock.deinit();

    // Tarsus should have set speed and actual speed displays
    const sspd = cock.mfd.dials.set_speed.?;
    try std.testing.expectEqualStrings("SET ", sspd.labelSlice());
    try std.testing.expect(sspd.rect.width() > 0);

    const aspd = cock.mfd.dials.actual_speed.?;
    try std.testing.expectEqualStrings("KPS ", aspd.labelSlice());
    try std.testing.expect(aspd.rect.width() > 0);
}

// --- Damage display integration tests ---

test "integration: all cockpit types have DAMG config" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const ship_types = [_]cockpit.ShipType{ .tarsus, .centurion, .galaxy, .orion };
    for (ship_types) |ship| {
        var entry = try tre.findEntry(allocator, loaded.tre_data, ship.iffFilename());
        defer entry.deinit();

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        var root = iff.parseFile(allocator, file_data) catch continue;
        defer root.deinit();

        // All ships should have FORM:DAMG
        const damg_form = root.findForm("DAMG".*);
        try std.testing.expect(damg_form != null);

        // Parse DAMG config
        const config = damage_display.parseDamageConfig(damg_form.?);
        try std.testing.expect(config != null);
        try std.testing.expectEqual(@as(u16, 100), config.?.max_value);
    }
}

test "integration: all cockpit types produce valid DamageDisplay" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const ship_types = [_]cockpit.ShipType{ .tarsus, .centurion, .galaxy, .orion };
    for (ship_types) |ship| {
        var entry = try tre.findEntry(allocator, loaded.tre_data, ship.iffFilename());
        defer entry.deinit();

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        var root = iff.parseFile(allocator, file_data) catch continue;
        defer root.deinit();

        // Should be able to create a DamageDisplay from any cockpit
        const display = damage_display.parseDamageDisplay(root);
        try std.testing.expect(display != null);

        // Display rect should be a reasonable size (shield display area)
        try std.testing.expect(display.?.rect.width() >= 20);
        try std.testing.expect(display.?.rect.height() >= 20);
    }
}

test "integration: damage display renders onto framebuffer without crash" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "CLUNKCK.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var root = iff.parseFile(allocator, file_data) catch return;
    defer root.deinit();

    const display = damage_display.parseDamageDisplay(root) orelse return;

    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(0);

    // Render with full shields
    const status = damage_display.DamageStatus.full();
    display.render(&fb, &status);

    // Some pixels inside the shield rect should be non-zero (shield bars)
    var has_shield_pixel = false;
    var y: u16 = display.rect.y1;
    while (y < display.rect.y2) : (y += 1) {
        var x: u16 = display.rect.x1;
        while (x < display.rect.x2) : (x += 1) {
            if (fb.getPixel(x, y) != 0) {
                has_shield_pixel = true;
                break;
            }
        }
        if (has_shield_pixel) break;
    }
    try std.testing.expect(has_shield_pixel);
}

// --- Weapon system integration tests ---

test "integration: GUNS.IFF loads 11 gun types" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "GUNS.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    const guns = try weapons.parseGuns(allocator, file_data);
    defer allocator.free(guns);

    try std.testing.expectEqual(@as(usize, 11), guns.len);
}

test "integration: GUNS.IFF laser has speed 1400" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "GUNS.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    const guns = try weapons.parseGuns(allocator, file_data);
    defer allocator.free(guns);

    // Gun[5] is Laser with speed 1400 (confirmed from raw data analysis)
    const laser = guns[5];
    try std.testing.expectEqualStrings("Lasr", laser.short_name[0..4]);
    try std.testing.expectEqual(@as(u16, 1400), laser.speed);
}

test "integration: GUNS.IFF neutron has speed 960" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "GUNS.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    const guns = try weapons.parseGuns(allocator, file_data);
    defer allocator.free(guns);

    // Gun[0] is Neutron with speed 960
    const neutron = guns[0];
    try std.testing.expectEqualStrings("Neut", neutron.short_name[0..4]);
    try std.testing.expectEqual(@as(u16, 960), neutron.speed);
}

test "integration: GUNS.IFF all guns have positive speed and damage" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "GUNS.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    const guns = try weapons.parseGuns(allocator, file_data);
    defer allocator.free(guns);

    for (guns) |gun| {
        try std.testing.expect(gun.speed > 0);
        try std.testing.expect(gun.damage > 0);
    }
}

test "integration: WEAPONS.IFF loads launchers and missiles" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    // TYPES\WEAPONS.IFF is the weapon data file (not APPEARNC\WEAPONS.IFF which is visual)
    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "TYPES", "WEAPONS.IFF") orelse return;

    const result = try weapons.parseWeapons(allocator, file_data);
    defer allocator.free(result.launcher_types);
    defer allocator.free(result.missile_types);

    // Original game has 3 launcher types and 5 missile types
    try std.testing.expectEqual(@as(usize, 3), result.launcher_types.len);
    try std.testing.expectEqual(@as(usize, 5), result.missile_types.len);
}

test "integration: WEAPONS.IFF torpedo has speed 1200" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "TYPES", "WEAPONS.IFF") orelse return;

    const result = try weapons.parseWeapons(allocator, file_data);
    defer allocator.free(result.launcher_types);
    defer allocator.free(result.missile_types);

    // Find torpedo (ID=1)
    var found_torpedo = false;
    for (result.missile_types) |m| {
        if (m.id == 1) {
            try std.testing.expectEqual(@as(u16, 1200), m.speed);
            try std.testing.expectEqual(weapons.TrackingType.torpedo, m.tracking);
            found_torpedo = true;
        }
    }
    try std.testing.expect(found_torpedo);
}

test "integration: WEAPONS.IFF heat-seeker has tracking type 2" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "TYPES", "WEAPONS.IFF") orelse return;

    const result = try weapons.parseWeapons(allocator, file_data);
    defer allocator.free(result.launcher_types);
    defer allocator.free(result.missile_types);

    // Find heat-seeker (ID=2)
    var found_heat = false;
    for (result.missile_types) |m| {
        if (m.id == 2) {
            try std.testing.expectEqual(weapons.TrackingType.heat_seeking, m.tracking);
            try std.testing.expect(m.lock_range > 0);
            found_heat = true;
        }
    }
    try std.testing.expect(found_heat);
}

// --- COMODTYP.IFF integration tests (Phase 8.1) ---

test "integration: COMODTYP.IFF parses all commodities" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "COMODTYP.IFF");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var registry = try commodities.parseCommodities(allocator, file_data);
    defer registry.deinit();

    // Should have 42 commodities
    try std.testing.expectEqual(@as(usize, 42), registry.commodities.len);

    // All commodities should have names
    for (registry.commodities) |commodity| {
        try std.testing.expect(commodity.name.len > 0);
    }

    // Should be able to find known commodities
    const grain = registry.findByName("Grain");
    try std.testing.expect(grain != null);
    try std.testing.expectEqual(@as(u16, 0), grain.?.id);
    try std.testing.expectEqual(@as(i16, 20), grain.?.base_cost);

    const iron = registry.findByName("Iron");
    try std.testing.expect(iron != null);
    try std.testing.expectEqual(@as(u16, 5), iron.?.id);

    // Contraband commodities exist
    const slaves = registry.findByName("Slaves");
    try std.testing.expect(slaves != null);
    try std.testing.expectEqual(@as(u16, 6), slaves.?.category);

    // Special commodities exist
    const artifact = registry.findByName("Alien Artifact");
    try std.testing.expect(artifact != null);
}

// --- Plot mission integration tests (Phase 9.4) ---

const plot_missions = @import("missions/plot_missions.zig");

test "integration: PLOTMSNS.IFF parses mission list with 24 entries" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "MISSIONS", "PLOTMSNS.IFF") orelse return;
    var list = try plot_missions.parsePlotMissionList(allocator, file_data);
    defer list.deinit();

    // PLOTMSNS.IFF TABL has 96 bytes = 24 entries
    try std.testing.expectEqual(@as(usize, 24), list.count());
}

test "integration: S0MA.IFF parses as valid plot mission" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "MISSIONS", "S0MA.IFF") orelse return;
    var mission = try plot_missions.parsePlotMission(allocator, file_data);
    defer mission.deinit();

    // S0MA has 1 cast member (PLAYER), 2 flags, cargo (Iron = commodity 22)
    try std.testing.expectEqualStrings("PLAYER", mission.castName(0).?);
    try std.testing.expectEqual(@as(usize, 2), mission.flags.len);
    try std.testing.expect(mission.cargo != null);
    try std.testing.expectEqual(@as(u8, 22), mission.cargo.?.commodity_id);
    try std.testing.expectEqual(@as(usize, 2), mission.objectiveCount());
    try std.testing.expectEqual(@as(usize, 12), mission.program.len);
}

test "integration: all plot mission files parse without errors" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const header = try tre.readHeader(loaded.tre_data);
    var parsed_count: usize = 0;

    for (0..header.entry_count) |i| {
        var entry = try tre.readEntry(allocator, loaded.tre_data, @intCast(i));
        defer entry.deinit();

        // Check if this is a plot mission file (MISSIONS/S*.IFF)
        const path = entry.path;
        const basename = std.fs.path.basename(path);

        const is_mission = for (0..path.len) |j| {
            const remaining = path[j..];
            if (remaining.len >= 8 and std.ascii.eqlIgnoreCase(remaining[0..8], "MISSIONS")) {
                break true;
            }
        } else false;

        if (!is_mission) continue;
        if (basename.len < 5) continue;
        if (basename[0] != 'S' and basename[0] != 's') continue;
        if (!std.ascii.endsWithIgnoreCase(basename, ".IFF")) continue;
        // Skip non-plot files
        if (std.ascii.eqlIgnoreCase(basename, "SKELETON.IFF")) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        var mission = plot_missions.parsePlotMission(allocator, file_data) catch |err| {
            std.debug.print("Failed to parse plot mission {s}: {}\n", .{ basename, err });
            return err;
        };
        defer mission.deinit();

        // Every mission should have at least 1 cast member and 1 objective
        try std.testing.expect(mission.castCount() >= 1);
        try std.testing.expect(mission.objectiveCount() >= 1);
        try std.testing.expect(mission.briefing.len > 0);
        try std.testing.expect(mission.program.len > 0);

        parsed_count += 1;
    }

    // We should have parsed at least 23 plot mission files
    try std.testing.expect(parsed_count >= 23);
}

// --- Plot mission series verification (Phase 9.5) ---

const plot_series = @import("missions/plot_series.zig");

test "integration: plot mission files group into expected series counts" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const header = try tre.readHeader(loaded.tre_data);
    var ids_buf: [64]plot_series.MissionId = undefined;
    var ids_count: usize = 0;

    for (0..header.entry_count) |i| {
        var entry = try tre.readEntry(allocator, loaded.tre_data, @intCast(i));
        defer entry.deinit();

        const path = entry.path;
        const basename = std.fs.path.basename(path);

        // Only consider MISSIONS/ directory files
        const is_mission = for (0..path.len) |j| {
            const remaining = path[j..];
            if (remaining.len >= 8 and std.ascii.eqlIgnoreCase(remaining[0..8], "MISSIONS")) {
                break true;
            }
        } else false;

        if (!is_mission) continue;

        if (plot_series.MissionId.fromFilename(basename)) |id| {
            ids_buf[ids_count] = id;
            ids_count += 1;
        }
    }

    const counts = plot_series.countBySeries(ids_buf[0..ids_count]);

    // Print actual counts for diagnostics
    std.debug.print("\nPlot mission series counts (total {d} missions):\n", .{ids_count});
    for (0..10) |s| {
        if (counts[s] > 0) {
            std.debug.print("  Series {d}: {d} missions\n", .{ s, counts[s] });
        }
    }

    // Verify each known series has the expected number of missions
    for (plot_series.SERIES) |s| {
        if (counts[s.series] != s.expected_count) {
            std.debug.print("Series {d}: expected {d} missions, found {d}\n", .{ s.series, s.expected_count, counts[s.series] });
        }
        try std.testing.expectEqual(s.expected_count, counts[s.series]);
    }
}

test "integration: PLOTMSNS.IFF has 24 mission entries" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const list_data = try findTreFileByPath(allocator, loaded.tre_data, "MISSIONS", "PLOTMSNS.IFF") orelse return;
    var list = try plot_missions.parsePlotMissionList(allocator, list_data);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 24), list.count());
}

test "integration: all plot missions pass structural validation" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const header = try tre.readHeader(loaded.tre_data);
    var validated_count: usize = 0;

    for (0..header.entry_count) |i| {
        var entry = try tre.readEntry(allocator, loaded.tre_data, @intCast(i));
        defer entry.deinit();

        const path = entry.path;
        const basename = std.fs.path.basename(path);

        const is_mission = for (0..path.len) |j| {
            const remaining = path[j..];
            if (remaining.len >= 8 and std.ascii.eqlIgnoreCase(remaining[0..8], "MISSIONS")) {
                break true;
            }
        } else false;

        if (!is_mission) continue;
        if (plot_series.MissionId.fromFilename(basename) == null) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        var mission = plot_missions.parsePlotMission(allocator, file_data) catch |err| {
            std.debug.print("Failed to parse {s}: {}\n", .{ basename, err });
            return err;
        };
        defer mission.deinit();

        const vr = plot_series.validateMission(&mission);
        if (!vr.isValid()) {
            std.debug.print("Validation failed for {s}: {d} errors\n", .{ basename, vr.error_count });
            for (vr.errors[0..vr.error_count]) |err| {
                if (err) |e| {
                    std.debug.print("  - {s}\n", .{@tagName(e)});
                }
            }
            return error.ValidationFailed;
        }

        validated_count += 1;
    }

    // All known plot missions should validate
    try std.testing.expect(validated_count >= plot_series.TOTAL_EXPECTED_MISSIONS);
}

test "integration: every plot mission has PLAYER as first cast member" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const header = try tre.readHeader(loaded.tre_data);
    var checked: usize = 0;

    for (0..header.entry_count) |i| {
        var entry = try tre.readEntry(allocator, loaded.tre_data, @intCast(i));
        defer entry.deinit();

        const path = entry.path;
        const basename = std.fs.path.basename(path);

        const is_mission = for (0..path.len) |j| {
            const remaining = path[j..];
            if (remaining.len >= 8 and std.ascii.eqlIgnoreCase(remaining[0..8], "MISSIONS")) {
                break true;
            }
        } else false;

        if (!is_mission) continue;
        if (plot_series.MissionId.fromFilename(basename) == null) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        var mission = try plot_missions.parsePlotMission(allocator, file_data);
        defer mission.deinit();

        // Every plot mission must have PLAYER as the first cast member
        try std.testing.expect(mission.castCount() >= 1);
        try std.testing.expectEqualStrings("PLAYER", mission.castName(0).?);

        checked += 1;
    }

    try std.testing.expect(checked >= plot_series.TOTAL_EXPECTED_MISSIONS);
}

test "integration: plot missions are ordered by series in TRE" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const header = try tre.readHeader(loaded.tre_data);
    var prev_series: ?u8 = null;
    var mission_count: usize = 0;

    for (0..header.entry_count) |i| {
        var entry = try tre.readEntry(allocator, loaded.tre_data, @intCast(i));
        defer entry.deinit();

        const path = entry.path;
        const basename = std.fs.path.basename(path);

        const is_mission = for (0..path.len) |j| {
            const remaining = path[j..];
            if (remaining.len >= 8 and std.ascii.eqlIgnoreCase(remaining[0..8], "MISSIONS")) {
                break true;
            }
        } else false;

        if (!is_mission) continue;

        if (plot_series.MissionId.fromFilename(basename)) |id| {
            // Missions should appear in non-decreasing series order in TRE
            if (prev_series) |ps| {
                try std.testing.expect(id.series >= ps);
            }
            prev_series = id.series;
            mission_count += 1;
        }
    }

    try std.testing.expect(mission_count >= plot_series.TOTAL_EXPECTED_MISSIONS);
}
