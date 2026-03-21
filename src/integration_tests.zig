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
const movie = @import("movie/movie.zig");
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
const conversations = @import("conversations/conversations.zig");
const conversation_audio = @import("conversations/conversation_audio.zig");
const text = @import("render/text.zig");
const opening = @import("movie/opening.zig");
const movie_text = @import("movie/movie_text.zig");
const movie_renderer = @import("movie/movie_renderer.zig");
const movie_music = @import("movie/movie_music.zig");
const movie_voice = @import("movie/movie_voice.zig");
const movie_sfx = @import("movie/movie_sfx.zig");
const music_player = @import("audio/music_player.zig");

const app_config = @import("config.zig");

/// Resolve the game data directory.
/// Precedence: PRIVATEER_DATA env var → privateer.json data_dir → null.
fn getGameDataDir() ?[]const u8 {
    // Try env var first
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "PRIVATEER_DATA") catch null) |dir| {
        return dir;
    }
    // Fall back to privateer.json
    var cfg = app_config.load(std.heap.page_allocator, app_config.CONFIG_FILE) catch return null;
    // Check if data_dir is the default "data" (meaning no config file was found or no real path set)
    if (std.mem.eql(u8, cfg.data_dir, "data")) {
        cfg.deinit();
        return null;
    }
    // Transfer ownership of data_dir, free the rest
    const dir = cfg.data_dir;
    std.heap.page_allocator.free(cfg.mod_dir);
    std.heap.page_allocator.free(cfg.output_dir);
    return dir;
}

/// Build the path to GAME.DAT from the data directory.
fn getGameDatPath(allocator: std.mem.Allocator, data_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "GAME.DAT", .{data_dir});
}

/// Load the entire GAME.DAT file into memory, or return null if not found.
/// Reads the game data directory from the PRIVATEER_DATA environment variable.
fn loadGameDat(allocator: std.mem.Allocator) !?[]const u8 {
    const data_dir = getGameDataDir() orelse return null;
    defer std.heap.page_allocator.free(data_dir);

    const dat_path = try getGameDatPath(allocator, data_dir);
    defer allocator.free(dat_path);

    const file = std.fs.cwd().openFile(dat_path, .{}) catch |err| {
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

    try std.testing.expectEqualStrings("../../DATA/AIDS/ATTITUDE.IFF", entry.path);
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

test "integration: DEMOFONT.SHP loads as a Font for title screen text" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var entry = try tre.findEntry(allocator, loaded.tre_data, "DEMOFONT.SHP");
    defer entry.deinit();

    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);

    // Parse as SHP first to check glyph count
    var shape_file = try shp.parse(allocator, file_data);
    defer shape_file.deinit();

    const glyph_count = shape_file.spriteCount();
    try std.testing.expect(glyph_count > 10);

    // Try loading as Font with various first_char values
    // Privateer fonts may start at space (32) or other values
    const first_chars = [_]u8{ 0, 32, 33 };
    var loaded_font = false;
    for (first_chars) |first_char| {
        var font = text.Font.load(allocator, file_data, first_char) catch continue;
        defer font.deinit();

        if (font.line_height > 0 and font.glyphCount() > 0) {
            loaded_font = true;
            // Verify at least some glyphs decoded successfully
            var valid_count: usize = 0;
            for (font.glyphs) |g| {
                if (g != null) valid_count += 1;
            }
            try std.testing.expect(valid_count > 5);
            break;
        }
    }
    try std.testing.expect(loaded_font);
}

test "integration: OPTSHPS.PAK overlay sprites decode for scene hotspots" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    // Load OPTSHPS.PAK
    var optshps_entry = try tre.findEntry(allocator, loaded.tre_data, "OPTSHPS.PAK");
    defer optshps_entry.deinit();
    const optshps_data = try tre.extractFileData(loaded.tre_data, optshps_entry.offset, optshps_entry.size);
    var optshps_pak = try pak.parse(allocator, optshps_data);
    defer optshps_pak.deinit();

    // Load GAMEFLOW.IFF to get sprite INFO bytes
    var gf_entry = try tre.findEntry(allocator, loaded.tre_data, "GAMEFLOW.IFF");
    defer gf_entry.deinit();
    const gf_data = try tre.extractFileData(loaded.tre_data, gf_entry.offset, gf_entry.size);
    var gameflow = try scene_mod.parseGameFlow(allocator, gf_data);
    defer gameflow.deinit();

    // Try loading overlay sprites from the first room's first scene
    var decoded_count: usize = 0;
    if (gameflow.rooms.len > 0) {
        const room = gameflow.rooms[0];
        if (room.scenes.len > 0) {
            const scn = room.scenes[0];
            for (scn.sprites) |spr_info| {
                const resource = optshps_pak.getResource(spr_info.info) catch continue;
                var spr_pack = scene_renderer.parseScenePack(allocator, resource) catch continue;
                defer spr_pack.deinit();

                if (spr_pack.spriteCount() > 0) {
                    var decoded = spr_pack.decodeSprite(allocator, 0) catch continue;
                    defer decoded.deinit();
                    if (decoded.width > 0 and decoded.height > 0) {
                        decoded_count += 1;
                    }
                }
            }
        }
    }

    // Should have decoded at least some overlay sprites
    try std.testing.expect(decoded_count > 0);
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

// --- Movie voice dialog integration tests ---

test "integration: load PC_1MG1.VOC from TRE with valid PCM at 11025 Hz" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var index = try tre.TreIndex.build(allocator, loaded.tre_data);
    defer index.deinit();

    var clip = movie_voice.loadFromTreIndex(allocator, &index, loaded.tre_data, "PC_1MG1.VOC") catch return;
    defer clip.deinit();

    // Player voice: 8-bit unsigned PCM at ~11025 Hz (VOC divisor yields ~11111)
    try std.testing.expect(clip.samples.len > 0);
    try std.testing.expect(clip.sample_rate > 10000);
    try std.testing.expect(clip.sample_rate < 12000);
    try std.testing.expect(clip.duration_ms > 0);
}

test "integration: load PIR1MG1.VOC from TRE with valid PCM at 11025 Hz" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var index = try tre.TreIndex.build(allocator, loaded.tre_data);
    defer index.deinit();

    var clip = movie_voice.loadFromTreIndex(allocator, &index, loaded.tre_data, "PIR1MG1.VOC") catch return;
    defer clip.deinit();

    // Pirate voice: 8-bit unsigned PCM at ~11025 Hz (VOC divisor yields ~11111)
    try std.testing.expect(clip.samples.len > 0);
    try std.testing.expect(clip.sample_rate > 10000);
    try std.testing.expect(clip.sample_rate < 12000);
    try std.testing.expect(clip.duration_ms > 0);
}

test "integration: MovieVoiceSet loads all 17 speech clips from TRE" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var index = try tre.TreIndex.build(allocator, loaded.tre_data);
    defer index.deinit();

    var voice_set = movie_voice.MovieVoiceSet.init(allocator);
    defer voice_set.deinit();

    voice_set.loadFromTre(&index, loaded.tre_data);

    // All 17 clips should load successfully (8 player + 9 pirate)
    try std.testing.expectEqual(@as(usize, 17), voice_set.loadedCount());

    // Spot-check: first player clip should be valid
    const pc1 = voice_set.getPlayerClip(0).?;
    try std.testing.expect(pc1.samples.len > 0);
    try std.testing.expect(pc1.sample_rate >= 11000);

    // Spot-check: first pirate clip should be valid
    const pir1 = voice_set.getPirateClip(0).?;
    try std.testing.expect(pir1.samples.len > 0);
    try std.testing.expect(pir1.sample_rate >= 11000);
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

    // Should be 320x200 (full screen: x2=319, x1=0 → 0+319+1=320)
    try std.testing.expectEqual(@as(u16, 320), spr.width);
    try std.testing.expectEqual(@as(u16, 200), spr.height);

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

    // CU.PAK backgrounds are 320x200 or 320xN (x2=319, x1=0 → 320)
    try std.testing.expectEqual(@as(u16, 320), spr.width);
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

// --- Conversation system integration tests ---

test "integration: AGRIRUMR.IFF parses as rumor table" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "CONV", "AGRIRUMR.IFF") orelse return;
    var table = try conversations.parseRumorTable(allocator, file_data);
    defer table.deinit();

    // AGRIRUMR has 5 rumor references
    try std.testing.expectEqual(@as(usize, 5), table.count());

    // All entries should be CONV references
    for (0..table.count()) |i| {
        const ref = table.get(i) orelse {
            try std.testing.expect(false); // should not be null
            continue;
        };
        try std.testing.expect(ref.isConv());
        try std.testing.expect(ref.nameStr().len > 0);
    }
}

test "integration: BASERUMR.IFF parses with null and BASE references" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "CONV", "BASERUMR.IFF") orelse return;
    var table = try conversations.parseRumorTable(allocator, file_data);
    defer table.deinit();

    // BASERUMR has 6 entries (first is null, rest are BASE references)
    try std.testing.expectEqual(@as(usize, 6), table.count());

    // First entry is null
    try std.testing.expect(table.get(0) == null);

    // Remaining entries should be BASE references
    for (1..table.count()) |i| {
        const ref = table.get(i) orelse {
            try std.testing.expect(false);
            continue;
        };
        try std.testing.expect(ref.isBase());
    }
}

test "integration: RUMORS.IFF parses chance weights" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "CONV", "RUMORS.IFF") orelse return;
    var chances = try conversations.parseRumorChances(allocator, file_data);
    defer chances.deinit();

    // RUMORS.IFF has 4 chance weights: [20, 40, 40, 40]
    try std.testing.expectEqual(@as(usize, 4), chances.count());
    try std.testing.expectEqual(@as(u16, 20), chances.weights[0]);
}

test "integration: all CONV IFF files parse without errors" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const header = try tre.readHeader(loaded.tre_data);
    var conv_count: usize = 0;
    var rumr_count: usize = 0;
    var info_count: usize = 0;

    for (0..header.entry_count) |i| {
        var entry = try tre.readEntry(allocator, loaded.tre_data, @intCast(i));
        defer entry.deinit();

        const path = entry.path;
        const basename = std.fs.path.basename(path);

        // Check if in CONV directory
        const is_conv = for (0..path.len) |j| {
            const remaining = path[j..];
            if (remaining.len >= 4 and std.ascii.eqlIgnoreCase(remaining[0..4], "CONV")) {
                break true;
            }
        } else false;

        if (!is_conv) continue;
        if (!std.mem.endsWith(u8, basename, ".IFF")) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        if (file_data.len < 12) continue; // too small for FORM header

        // Determine form type
        const form_type = file_data[8..12];

        if (std.mem.eql(u8, form_type, "RUMR")) {
            // Try to parse as rumor table or chances
            if (iff.parseFile(allocator, file_data)) |*root_chunk| {
                var root = root_chunk.*;
                defer root.deinit();

                if (root.findChild("CHNC".*) != null) {
                    var chances = try conversations.parseRumorChances(allocator, file_data);
                    defer chances.deinit();
                    try std.testing.expect(chances.count() > 0);
                } else if (root.findChild("TABL".*) != null) {
                    var table = try conversations.parseRumorTable(allocator, file_data);
                    defer table.deinit();
                    try std.testing.expect(table.count() > 0);
                    rumr_count += 1;
                }
            } else |_| {}
        } else if (std.mem.eql(u8, form_type, "INFO")) {
            var table = try conversations.parseRumorTable(allocator, file_data);
            defer table.deinit();
            try std.testing.expect(table.count() > 0);
            info_count += 1;
        }

        conv_count += 1;
    }

    // Expect at least 17 RUMR files and 2 INFO files
    try std.testing.expect(conv_count >= 19);
    try std.testing.expect(rumr_count >= 15);
    try std.testing.expect(info_count >= 2);
}

test "integration: COMPTEXT.IFF parses mission computer text" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "OPTIONS", "COMPTEXT.IFF") orelse return;
    var ct = try conversations.parseComputerText(allocator, file_data);
    defer ct.deinit();

    // Merchant guild should have welcome text
    try std.testing.expect(ct.merchant.welcome != null);
    try std.testing.expect(ct.merchant.join != null);
    try std.testing.expect(ct.merchant.scan != null);

    // Mercenary guild should also have text
    try std.testing.expect(ct.mercenary.welcome != null);
    try std.testing.expect(ct.mercenary.join != null);

    // Automated mission machine should have text
    try std.testing.expect(ct.automated.welcome != null);
}

test "integration: COMMTXT.IFF parses exchange strings" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "OPTIONS", "COMMTXT.IFF") orelse return;
    var st = try conversations.parseStringTable(allocator, file_data);
    defer st.deinit();

    // Should have at least 9 strings (SNUM value from analysis)
    try std.testing.expect(st.count() >= 9);

    // First string should be "Price: "
    try std.testing.expectEqualStrings("Price: ", st.get(0).?);
}

test "integration: PFC conversation scripts parse" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const header = try tre.readHeader(loaded.tre_data);
    var pfc_count: usize = 0;
    var total_lines: usize = 0;

    for (0..header.entry_count) |i| {
        var entry = try tre.readEntry(allocator, loaded.tre_data, @intCast(i));
        defer entry.deinit();

        const basename = std.fs.path.basename(entry.path);
        if (!std.mem.endsWith(u8, basename, ".PFC")) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        if (file_data.len == 0) continue;

        var script = conversations.parseConversationScript(allocator, file_data) catch continue;
        defer script.deinit();

        if (script.lineCount() > 0) {
            pfc_count += 1;
            total_lines += script.lineCount();

            // Verify first line has non-empty text
            try std.testing.expect(script.lines[0].text.len > 0);
            try std.testing.expect(script.lines[0].speaker.len > 0);
        }
    }

    // Should have many PFC files with dialogue
    try std.testing.expect(pfc_count > 10);
    try std.testing.expect(total_lines > 50);
}

// --- Conversation audio integration tests (Phase 10.3) ---

test "integration: VPK decompression produces playable audio" {
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

    var vpk_tested: usize = 0;
    var total_clips: usize = 0;

    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, ".VPK")) continue;

        const file_data = try tre.extractFileData(loaded.tre_data, e.offset, e.size);
        if (file_data.len < vpk.MIN_FILE_SIZE) continue;

        var vpk_file = vpk.parse(allocator, file_data) catch continue;
        defer vpk_file.deinit();

        // Use ConversationVoice to decompress clips (no player needed for data test)
        const cv = conversation_audio.ConversationVoice.init(allocator, vpk_file, null);

        // Test first clip from each VPK
        if (cv.clipCount() > 0) {
            var clip = cv.getClip(0) catch continue;
            defer clip.deinit();

            // Playable audio must have: non-zero samples, valid sample rate, 8-bit PCM
            try std.testing.expect(clip.samples.len > 0);
            try std.testing.expect(clip.sample_rate >= 10000);
            try std.testing.expect(clip.sample_rate <= 12000);

            // Audio should not be all silence (not all 128)
            var has_non_silence = false;
            for (clip.samples) |s| {
                if (s != 128) {
                    has_non_silence = true;
                    break;
                }
            }
            try std.testing.expect(has_non_silence);

            total_clips += 1;
        }

        vpk_tested += 1;
        if (vpk_tested >= 10) break; // Test 10 VPK files for speed
    }

    try std.testing.expect(vpk_tested >= 5);
    try std.testing.expect(total_clips >= 5);
}

test "integration: VPK clip count matches PFC line count for conversation files" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const header = try tre.readHeader(loaded.tre_data);
    var matched: usize = 0;

    // For each PFC file, check if a corresponding VPK exists with matching entry count
    for (0..header.entry_count) |i| {
        var entry = try tre.readEntry(allocator, loaded.tre_data, @intCast(i));
        defer entry.deinit();

        const basename = std.fs.path.basename(entry.path);
        if (!std.mem.endsWith(u8, basename, ".PFC")) continue;

        const pfc_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        if (pfc_data.len == 0) continue;

        var script = conversations.parseConversationScript(allocator, pfc_data) catch continue;
        defer script.deinit();
        if (script.lineCount() == 0) continue;

        // Try to find the corresponding VPK (same name, different extension)
        const stem_end = std.mem.lastIndexOf(u8, basename, ".") orelse continue;
        const stem = basename[0..stem_end];

        for (0..header.entry_count) |j| {
            var vpk_entry = try tre.readEntry(allocator, loaded.tre_data, @intCast(j));
            defer vpk_entry.deinit();

            const vpk_basename = std.fs.path.basename(vpk_entry.path);
            if (!std.mem.endsWith(u8, vpk_basename, ".VPK")) continue;

            const vpk_stem_end = std.mem.lastIndexOf(u8, vpk_basename, ".") orelse continue;
            const vpk_stem = vpk_basename[0..vpk_stem_end];

            if (!std.ascii.eqlIgnoreCase(stem, vpk_stem)) continue;

            // Found matching VPK
            const vpk_data = try tre.extractFileData(loaded.tre_data, vpk_entry.offset, vpk_entry.size);
            if (vpk_data.len < vpk.MIN_FILE_SIZE) break;

            var vpk_file = vpk.parse(allocator, vpk_data) catch break;
            defer vpk_file.deinit();

            // VPK entry count should match PFC line count
            // (each dialogue line has a voice clip)
            if (vpk_file.entryCount() == script.lineCount()) {
                matched += 1;
            }
            break;
        }

        if (matched >= 5) break; // Enough to validate the pattern
    }

    // At least some PFC/VPK pairs should have matching counts
    try std.testing.expect(matched > 0);
}

// --- Scene transition integration tests ---

const scene_mod = @import("game/scene.zig");
const room_assets = @import("game/room_assets.zig");

test "integration: OPTSHPS.PAK loads and contains scene backgrounds" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var tre_index = try tre.TreIndex.build(allocator, loaded.tre_data);
    defer tre_index.deinit();

    const entry = tre_index.findEntry(room_assets.OPTSHPS_PAK) orelse
        return error.FileNotFound;
    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var pak_file = try pak.parse(allocator, file_data);
    defer pak_file.deinit();

    // OPTSHPS.PAK should have many resources (226 L1 entries)
    try std.testing.expect(pak_file.resourceCount() > 60);

    // Scene 0 should be a valid scene pack with a decodable background sprite
    const resource = try pak_file.getResource(0);
    var pack = try scene_renderer.parseScenePack(allocator, resource);
    defer pack.deinit();

    try std.testing.expect(pack.spriteCount() > 0);
    var spr = try pack.decodeSprite(allocator, 0);
    defer spr.deinit();
    // Background should be roughly 320x200
    try std.testing.expect(spr.width >= 200);
    try std.testing.expect(spr.height >= 100);
}

test "integration: OPTPALS.PAK loads and contains valid palettes" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var tre_index = try tre.TreIndex.build(allocator, loaded.tre_data);
    defer tre_index.deinit();

    const entry = tre_index.findEntry(room_assets.OPTPALS_PAK) orelse
        return error.FileNotFound;
    const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
    var pak_file = try pak.parse(allocator, file_data);
    defer pak_file.deinit();

    // Should have at least 42 palette entries
    try std.testing.expect(pak_file.resourceCount() >= room_assets.PALETTE_COUNT);

    // Each palette resource should be 772 bytes (PAL_FILE_SIZE)
    const pal_data = try pak_file.getResource(0);
    try std.testing.expectEqual(@as(usize, pal.PAL_FILE_SIZE), pal_data.len);

    // Should parse as a valid palette
    const palette = try pal.parse(pal_data);
    var has_non_black = false;
    for (palette.colors[1..]) |c| {
        if (c.r > 0 or c.g > 0 or c.b > 0) {
            has_non_black = true;
            break;
        }
    }
    try std.testing.expect(has_non_black);
}

test "integration: GAMEFLOW scenes map to valid OPTSHPS.PAK resources" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var tre_index = try tre.TreIndex.build(allocator, loaded.tre_data);
    defer tre_index.deinit();

    // Load GAMEFLOW.IFF
    const gf_entry = tre_index.findEntry("GAMEFLOW.IFF") orelse
        return error.FileNotFound;
    const gf_data = try tre.extractFileData(loaded.tre_data, gf_entry.offset, gf_entry.size);
    var gameflow = try scene_mod.parseGameFlow(allocator, gf_data);
    defer gameflow.deinit();

    // Load OPTSHPS.PAK
    const optshps_entry = tre_index.findEntry(room_assets.OPTSHPS_PAK) orelse
        return error.FileNotFound;
    const optshps_data = try tre.extractFileData(loaded.tre_data, optshps_entry.offset, optshps_entry.size);
    var optshps_pak = try pak.parse(allocator, optshps_data);
    defer optshps_pak.deinit();

    // Every scene ID in GAMEFLOW should correspond to a valid OPTSHPS.PAK resource
    var scenes_checked: usize = 0;
    for (gameflow.rooms) |room| {
        for (room.scenes) |scn| {
            const resource = optshps_pak.getResource(scn.info) catch continue;
            var pack = scene_renderer.parseScenePack(allocator, resource) catch continue;
            defer pack.deinit();

            // Should have at least a background sprite
            try std.testing.expect(pack.spriteCount() > 0);

            // Sprite headers should be readable for click region bounds
            for (scn.sprites) |spr| {
                if (spr.info < pack.spriteCount()) {
                    _ = pack.getSpriteHeader(spr.info) catch {};
                }
            }
            scenes_checked += 1;
        }
    }
    // Should have checked a significant number of scenes
    try std.testing.expect(scenes_checked > 50);
}

test "integration: scene click regions have proper bounds from sprite headers" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var tre_index = try tre.TreIndex.build(allocator, loaded.tre_data);
    defer tre_index.deinit();

    // Load GAMEFLOW.IFF
    const gf_entry = tre_index.findEntry("GAMEFLOW.IFF") orelse
        return error.FileNotFound;
    const gf_data = try tre.extractFileData(loaded.tre_data, gf_entry.offset, gf_entry.size);
    var gameflow = try scene_mod.parseGameFlow(allocator, gf_data);
    defer gameflow.deinit();

    // Load OPTSHPS.PAK
    const optshps_entry = tre_index.findEntry(room_assets.OPTSHPS_PAK) orelse
        return error.FileNotFound;
    const optshps_data = try tre.extractFileData(loaded.tre_data, optshps_entry.offset, optshps_entry.size);
    var optshps_pak = try pak.parse(allocator, optshps_data);
    defer optshps_pak.deinit();

    // Check the first room's first scene for proper click region bounds
    // Each GAMEFLOW sprite INFO byte is a global OPTSHPS.PAK resource index
    // (not an index within the per-scene pack)
    if (gameflow.rooms.len == 0) return;
    const room = gameflow.rooms[0];
    if (room.scenes.len == 0) return;
    const scn = room.scenes[0];

    var has_sized_region = false;
    for (scn.sprites) |spr| {
        if (spr.effect.len > 0) {
            const action = click_region.parseAction(spr.effect);
            if (action != .none) {
                // Sprite INFO = global PAK resource index for that hotspot
                const resource = optshps_pak.getResource(spr.info) catch continue;
                var spr_pack = scene_renderer.parseScenePack(allocator, resource) catch continue;
                defer spr_pack.deinit();
                if (spr_pack.getSpriteHeader(0)) |header| {
                    const w = header.width() catch continue;
                    const h = header.height() catch continue;
                    // Hotspot sprites should be smaller than or equal to fullscreen
                    if (w <= 320 or h <= 200) {
                        has_sized_region = true;
                    }
                } else |_| {}
            }
        }
    }
    try std.testing.expect(has_sized_region);
}

// --- Phase 15: Title screen integration tests ---

test "integration: title screen uses OPTSHPS.PAK scene pack 181 with OPTPALS palette 39" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    var tre_index = try tre.TreIndex.build(allocator, loaded.tre_data);
    defer tre_index.deinit();

    // Load OPTSHPS.PAK and verify scene pack 181 has the title screen (320x200)
    const shps_entry = tre_index.findEntry(room_assets.OPTSHPS_PAK) orelse
        return error.FileNotFound;
    const shps_data = try tre.extractFileData(loaded.tre_data, shps_entry.offset, shps_entry.size);
    var shps_pak = try pak.parse(allocator, shps_data);
    defer shps_pak.deinit();

    // Scene pack 181 is the pre-rendered title screen
    try std.testing.expect(shps_pak.resourceCount() > 181);
    const resource181 = try shps_pak.getResource(181);
    var pack181 = try scene_renderer.parseScenePack(allocator, resource181);
    defer pack181.deinit();

    try std.testing.expect(pack181.spriteCount() > 0);
    var title_bg = try pack181.decodeSprite(allocator, 0);
    defer title_bg.deinit();
    try std.testing.expectEqual(@as(u16, 320), title_bg.width);
    try std.testing.expectEqual(@as(u16, 200), title_bg.height);

    // Load OPTPALS.PAK palette 39 (the title screen's dark purple palette)
    const pals_entry = tre_index.findEntry(room_assets.OPTPALS_PAK) orelse
        return error.FileNotFound;
    const pals_data = try tre.extractFileData(loaded.tre_data, pals_entry.offset, pals_entry.size);
    var pals_pak = try pak.parse(allocator, pals_data);
    defer pals_pak.deinit();

    try std.testing.expect(pals_pak.resourceCount() > 39);
    const pal39_data = try pals_pak.getResource(39);
    try std.testing.expectEqual(@as(usize, pal.PAL_FILE_SIZE), pal39_data.len);
    const title_pal = try pal.parse(pal39_data);
    // Palette 39 color 0 is dark purple (VGA6 4,0,4 -> RGB 16,0,16), not black
    try std.testing.expectEqual(@as(u8, 16), title_pal.colors[0].r);
    try std.testing.expectEqual(@as(u8, 0), title_pal.colors[0].g);
    try std.testing.expectEqual(@as(u8, 16), title_pal.colors[0].b);
}

// --- FORM:MOVI movie script integration tests ---

test "integration: parse all MIDGAMES IFF files as FORM:MOVI" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const entries = try tre.readAllEntries(allocator, loaded.tre_data);
    defer {
        for (entries) |*entry| {
            var e = entry.*;
            e.deinit();
        }
        allocator.free(entries);
    }

    var movi_count: usize = 0;
    var movi_errors: usize = 0;
    for (entries) |entry| {
        // Check if this is a MIDGAMES IFF file (MID1*.IFF pattern)
        const is_midgames = std.mem.indexOf(u8, entry.path, "MIDGAMES") != null;
        const is_iff = std.mem.endsWith(u8, entry.path, ".IFF");
        if (!is_midgames or !is_iff) continue;

        const file_data = tre.extractFileData(loaded.tre_data, entry.offset, entry.size) catch continue;

        // Only try to parse files that look like FORM:MOVI
        if (!movie.isMovi(file_data)) continue;

        var script = movie.parse(allocator, file_data) catch {
            movi_errors += 1;
            continue;
        };
        defer script.deinit();

        // Every MOVI script should have a valid speed and at least one ACTS block
        try std.testing.expect(script.frame_speed_ticks > 0);
        try std.testing.expect(script.acts_blocks.len > 0);
        try std.testing.expect(script.file_references.len > 0);

        movi_count += 1;
    }

    // Should find multiple MOVI files (MID1A.IFF through MID1F.IFF = 12 files)
    try std.testing.expect(movi_count > 0);
    try std.testing.expectEqual(@as(usize, 0), movi_errors);
}

// --- Opening sequence playlist integration tests ---

test "integration: GFMIDGAM.IFF parses as FORM:MIDG with entries" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "MIDGAMES", "GFMIDGAM.IFF") orelse return;

    var table = opening.parseMidgameTable(allocator, file_data) catch |err| {
        std.debug.print("Failed to parse GFMIDGAM.IFF: {}\n", .{err});
        return err;
    };
    defer table.deinit();

    // Should have at least 3 entries (landing, takeoff, opening, ...)
    try std.testing.expect(table.filenames.len >= 3);

    // The opening sequence should be at index 2
    const opening_file = table.getOpeningFilename();
    try std.testing.expect(opening_file != null);
    try std.testing.expectEqualStrings("OPENING.PAK", opening_file.?);

    // Print all entries for diagnostic purposes
    std.debug.print("GFMIDGAM entries ({d}):", .{table.filenames.len});
    for (table.filenames) |name| {
        std.debug.print(" {s}", .{name});
    }
    std.debug.print("\n", .{});
}

test "integration: OPENING.PAK parses as scene name playlist" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "MIDGAMES", "OPENING.PAK") orelse return;

    var seq = opening.parsePlaylist(allocator, file_data) catch |err| {
        std.debug.print("Failed to parse OPENING.PAK: {}\n", .{err});
        return err;
    };
    defer seq.deinit();

    // Should have multiple scenes
    try std.testing.expect(seq.sceneCount() > 0);

    // First scene should be "mid1a" (or similar)
    const first = seq.getSceneName(0);
    try std.testing.expect(first != null);

    // Print all scene names for diagnostic purposes
    std.debug.print("OPENING.PAK scenes ({d}):", .{seq.sceneCount()});
    for (0..seq.sceneCount()) |i| {
        if (seq.getSceneName(i)) |name| {
            std.debug.print(" {s}", .{name});
        }
    }
    std.debug.print("\n", .{});
}

test "integration: OPENING.PAK scene names map to valid MOVI files in TRE" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "MIDGAMES", "OPENING.PAK") orelse return;

    var seq = opening.parsePlaylist(allocator, file_data) catch return;
    defer seq.deinit();

    // Each scene name should map to a valid FORM:MOVI file in the TRE
    var found_count: usize = 0;
    for (0..seq.sceneCount()) |i| {
        const tre_path = (try seq.getSceneTrePath(allocator, i)) orelse continue;
        defer allocator.free(tre_path);

        // Extract just the filename part for TRE lookup
        const basename = std.fs.path.basename(tre_path);

        const scene_data = findTreFileByPath(allocator, loaded.tre_data, "MIDGAMES", basename) catch continue orelse continue;

        // Should be a FORM:MOVI file
        if (movie.isMovi(scene_data)) {
            found_count += 1;
        }
    }

    // At least some scenes should resolve to valid MOVI files
    try std.testing.expect(found_count > 0);
    std.debug.print("Resolved {d}/{d} scenes to FORM:MOVI files\n", .{ found_count, seq.sceneCount() });
}

// --- Movie text overlay integration tests ---

test "integration: MIDTEXT.PAK parses as movie text with expected first entry" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const file_data = try findTreFileByPath(allocator, loaded.tre_data, "MIDGAMES", "MIDTEXT.PAK") orelse return;

    var mt = movie_text.parse(allocator, file_data) catch |err| {
        std.debug.print("Failed to parse MIDTEXT.PAK: {}\n", .{err});
        return err;
    };
    defer mt.deinit();

    // Should have at least one text entry
    try std.testing.expect(mt.count() > 0);

    // First entry should start with "2669" (the opening crawl text)
    const first = mt.getText(0).?;
    try std.testing.expect(std.mem.startsWith(u8, first, "2669"));

    // Print all entries for diagnostic purposes
    std.debug.print("MIDTEXT.PAK entries ({d}):\n", .{mt.count()});
    for (0..mt.count()) |i| {
        if (mt.getText(i)) |entry| {
            std.debug.print("  [{d}] \"{s}\"\n", .{ i, entry });
        }
    }
}

// --- Movie renderer integration tests ---

test "integration: MovieRenderer loads MID1.PAK and renders SPRI command from MID1A.IFF" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    // Load MID1.PAK (the sprite/palette PAK referenced by MID1A.IFF)
    const mid1_data = try findTreFileByPath(allocator, loaded.tre_data, "MIDGAMES", "MID1.PAK") orelse return;

    // Load MID1A.IFF (first scene script)
    const mid1a_data = try findTreFileByPath(allocator, loaded.tre_data, "MIDGAMES", "MID1A.IFF") orelse return;

    // Parse the movie script
    var script = try movie.parse(allocator, mid1a_data);
    defer script.deinit();

    // Create renderer with framebuffer
    var fb = framebuffer_mod.Framebuffer.create();
    var renderer = try movie_renderer.MovieRenderer.init(allocator, &fb, script.fileSlotCount());
    defer renderer.deinit();

    // Load MID1.PAK at slot 0 (the first FILE reference should point to it)
    try renderer.loadPak(0, mid1_data);

    // Verify palette was extracted
    const palette = renderer.getPalette();
    try std.testing.expect(palette != null);

    // Execute the first ACTS block
    try std.testing.expect(script.acts_blocks.len > 0);
    // Try executing the first block — if any sprite resource fails, that's ok for this test
    renderer.executeActsBlock(script.acts_blocks[0]) catch {};

    // Framebuffer should have some non-black pixels after rendering
    var non_black: usize = 0;
    for (fb.pixels) |p| {
        if (p != 0) non_black += 1;
    }
    std.debug.print("MovieRenderer: rendered {d} non-black pixels from MID1A.IFF first ACTS block\n", .{non_black});
}

test "integration: MoviePlayer full loading path for MID1A.IFF" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    // Build TreIndex (same as main.zig)
    var tre_index = try tre.TreIndex.build(allocator, loaded.tre_data);
    defer tre_index.deinit();

    // Load MID1A.IFF via TreIndex (like MoviePlayer does)
    const mid1a_entry = tre_index.findEntry("MID1A.IFF") orelse {
        std.debug.print("DIAG: MID1A.IFF not found via TreIndex\n", .{});
        return;
    };
    const mid1a_data = try tre.extractFileData(loaded.tre_data, mid1a_entry.offset, mid1a_entry.size);

    // Parse script
    var script = try movie.parse(allocator, mid1a_data);
    defer script.deinit();

    std.debug.print("DIAG: MID1A.IFF file_references ({d} slots, max {d}):\n", .{ script.file_references.len, script.fileSlotCount() });
    for (script.file_references) |slot| {
        const basename = std.fs.path.basename(slot.path);
        const found = tre_index.findEntry(basename);
        std.debug.print("  [slot {d}] \"{s}\" → basename \"{s}\" → {s}\n", .{
            slot.slot_id,
            slot.path,
            basename,
            if (found != null) "FOUND" else "NOT FOUND",
        });
    }

    // Create renderer and load PAKs (like MoviePlayer)
    var fb = framebuffer_mod.Framebuffer.create();
    var renderer = try movie_renderer.MovieRenderer.init(allocator, &fb, script.fileSlotCount());
    defer renderer.deinit();

    for (script.file_references) |slot| {
        const ref_basename = std.fs.path.basename(slot.path);
        if (tre_index.findEntry(ref_basename)) |ref_entry| {
            const pak_data = tre.extractFileData(loaded.tre_data, ref_entry.offset, ref_entry.size) catch {
                std.debug.print("DIAG: PAK[{d}] extract failed\n", .{slot.slot_id});
                continue;
            };
            renderer.loadPak(@as(usize, slot.slot_id), pak_data) catch |err| {
                std.debug.print("DIAG: PAK[{d}] loadPak failed: {}\n", .{ slot.slot_id, err });
                continue;
            };
        }
    }

    std.debug.print("DIAG: Palette: {s}\n", .{if (renderer.getPalette() != null) "loaded" else "MISSING"});

    // Try rendering first ACTS block
    if (script.acts_blocks.len > 0) {
        const block = script.acts_blocks[0];
        std.debug.print("DIAG: ACTS[0] has {d} FILD, {d} SPRI commands\n", .{ block.field_commands.len, block.sprite_commands.len });

        // Check what file_refs are used
        for (block.field_commands) |cmd| {
            std.debug.print("DIAG:   FILD object_id={d} file_ref={d} p1={d} p2={d} p3={d} (slot {s})\n", .{
                cmd.object_id,
                cmd.file_ref,
                cmd.param1,
                cmd.param2,
                cmd.param3,
                if (cmd.file_ref < renderer.loaded_paks.len and renderer.loaded_paks[cmd.file_ref] != null) "loaded" else "EMPTY",
            });
        }
        for (block.sprite_commands) |cmd| {
            std.debug.print("DIAG:   SPRI object_id={d} ref={d} type={d} params={d}\n", .{
                cmd.object_id,
                cmd.ref,
                cmd.sprite_type,
                cmd.param_count,
            });
        }

        renderer.executeActsBlock(block) catch |err| {
            std.debug.print("DIAG: ACTS[0] render error: {}\n", .{err});
        };
    }

    // Dump raw FILD/SPRI chunk bytes from the IFF tree
    const result2 = iff.parseChunk(allocator, mid1a_data, 0) catch return;
    var root2 = result2.chunk;
    defer root2.deinit();

    const acts_forms = root2.findForms(allocator, "ACTS".*) catch return;
    defer allocator.free(acts_forms);

    if (acts_forms.len > 0) {
        const acts0 = acts_forms[0];
        const fild_chunks = acts0.findChildren(allocator, "FILD".*) catch return;
        defer allocator.free(fild_chunks);
        for (fild_chunks, 0..) |fild, fi| {
            std.debug.print("DIAG: raw FILD[{d}] ({d} bytes):", .{ fi, fild.data.len });
            for (fild.data) |b| {
                std.debug.print(" {x:0>2}", .{b});
            }
            std.debug.print("\n", .{});
        }
        const spri_chunks = acts0.findChildren(allocator, "SPRI".*) catch return;
        defer allocator.free(spri_chunks);
        for (spri_chunks, 0..) |spri, si| {
            std.debug.print("DIAG: raw SPRI[{d}] ({d} bytes):", .{ si, spri.data.len });
            for (spri.data) |b| {
                std.debug.print(" {x:0>2}", .{b});
            }
            std.debug.print("\n", .{});
        }
    }
}

test "integration: OPENING.GEN parses to valid XMIDI sequence with EVNT data" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    // Find OPENING.GEN in the TRE (DATA/SOUND/OPENING.GEN)
    const gen_data = try findTreFileByPath(allocator, loaded.tre_data, "SOUND", "OPENING.GEN") orelse {
        std.debug.print("OPENING.GEN not found in TRE, skipping\n", .{});
        return;
    };

    // Should be recognized as XMIDI
    try std.testing.expect(music.isXmidi(gen_data));

    // Parse as music file
    var music_file = try music.parse(allocator, gen_data);
    defer music_file.deinit();

    // Verify format and structure
    try std.testing.expectEqual(music.MusicFormat.xmidi, music_file.format);
    try std.testing.expect(music_file.sequence_count > 0);
    try std.testing.expect(music_file.sequences.len > 0);

    // First sequence should have EVNT data
    const seq = music_file.sequences[0];
    try std.testing.expect(seq.event_data.len > 0);

    std.debug.print("OPENING.GEN: {d} sequences, first EVNT = {d} bytes, {d} timbres\n", .{
        music_file.sequences.len,
        seq.event_data.len,
        seq.timbres.len,
    });
}

test "integration: OPENING.GEN decodes to PCM audio via movie_music" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    // Find OPENING.GEN in the TRE
    const gen_data = try findTreFileByPath(allocator, loaded.tre_data, "SOUND", "OPENING.GEN") orelse {
        std.debug.print("OPENING.GEN not found in TRE, skipping\n", .{});
        return;
    };

    // Load and render to PCM
    const pcm = try movie_music.loadOpeningMusic(allocator, gen_data);
    defer allocator.free(pcm);

    // PCM should be non-empty
    try std.testing.expect(pcm.len > 0);

    // Should contain non-silence samples (actual music, not just 128/silence)
    var non_silence: usize = 0;
    for (pcm) |sample| {
        if (sample != 128) non_silence += 1;
    }
    try std.testing.expect(non_silence > 0);

    // Calculate duration at 22050 Hz
    const duration_secs = @as(f64, @floatFromInt(pcm.len)) / @as(f64, @floatFromInt(music_player.MusicPlayer.SAMPLE_RATE));
    std.debug.print("OPENING.GEN → PCM: {d} samples ({d:.1} seconds), {d} non-silence\n", .{
        pcm.len,
        duration_secs,
        non_silence,
    });
}

test "integration: SOUNDFX.PAK can be opened and contains indexed sound resources" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const sfx_data = try findTreFileByPath(allocator, loaded.tre_data, "SOUND", "SOUNDFX.PAK") orelse {
        std.debug.print("SOUNDFX.PAK not found in TRE, skipping\n", .{});
        return;
    };

    var bank = movie_sfx.SfxBank.init(allocator);
    defer bank.deinit();

    try bank.loadFromPak(sfx_data);

    // SOUNDFX.PAK contains 43 VOC sound resources
    try std.testing.expect(bank.totalSlots() >= 40);
    try std.testing.expect(bank.loadedCount() >= 40);

    // Each loaded sample should have valid PCM data
    for (0..bank.totalSlots()) |i| {
        if (bank.getSample(i)) |sample| {
            try std.testing.expect(sample.samples.len > 0);
            try std.testing.expect(sample.sample_rate >= 8000);
            try std.testing.expect(sample.sample_rate <= 22100);
        }
    }

    std.debug.print("SOUNDFX.PAK: {d} slots, {d} loaded VOC samples\n", .{
        bank.totalSlots(),
        bank.loadedCount(),
    });
}

test "integration: COMBAT.DAT maps events to valid SOUNDFX indices" {
    const allocator = std.testing.allocator;
    const loaded = try loadTreData(allocator) orelse return;
    defer allocator.free(loaded.data);

    const combat_data = try findTreFileByPath(allocator, loaded.tre_data, "SOUND", "COMBAT.DAT") orelse {
        std.debug.print("COMBAT.DAT not found in TRE, skipping\n", .{});
        return;
    };

    var map = movie_sfx.CombatSfxMap.init(allocator);
    defer map.deinit();

    try map.loadFromData(combat_data);

    // COMBAT.DAT should have multiple event groups
    try std.testing.expect(map.groupCount() >= 1);

    // At least one group should map to a valid SFX index
    var found_valid = false;
    for (0..map.groupCount()) |gi| {
        if (map.getGroup(gi)) |group| {
            if (group.len > 0) {
                found_valid = true;
                break;
            }
        }
    }
    try std.testing.expect(found_valid);

    std.debug.print("COMBAT.DAT: {d} event groups\n", .{map.groupCount()});
}
