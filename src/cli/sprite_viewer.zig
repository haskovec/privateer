//! Sprite viewer core logic for listing and viewing sprites from
//! Wing Commander: Privateer game data (GAME.DAT / extracted files).
//! Supports SHP, PAK (with recursive IFF dig), and IFF files.

const std = @import("std");
const iso9660 = @import("../formats/iso9660.zig");
const tre = @import("../formats/tre.zig");
const iff_mod = @import("../formats/iff.zig");
const sprite_mod = @import("../formats/sprite.zig");
const shp_mod = @import("../formats/shp.zig");
const pak_mod = @import("../formats/pak.zig");
const pal_mod = @import("../formats/pal.zig");
const render_mod = @import("../render/render.zig");
const scene_renderer = @import("../render/scene_renderer.zig");
const png_mod = @import("../render/png.zig");
const upscale_mod = @import("../render/upscale.zig");
const kitty = @import("../render/kitty_graphics.zig");

/// Default palette path within the TRE archive.
pub const DEFAULT_PALETTE_PATH = "PALETTE/PCMAIN.PAL";

/// Detected file format for sprite containers.
pub const FileFormat = enum {
    shp,
    iff,
    pak,
    unknown,
};

/// Information about a sprite-containing file for the list command.
pub const SpriteFileInfo = struct {
    path: []const u8,
    format: FileFormat,
    sprite_count: u32,
};

/// Detect the format of a file by extension, with magic-byte fallback.
/// If the extension suggests a format but magic bytes indicate a different one,
/// the magic bytes win — this handles files with wrong/misleading extensions.
pub fn detectFormat(filename: []const u8, data: []const u8) FileFormat {
    const sniffed = sniffFormat(data);

    // If magic bytes give a definitive answer, trust them over the extension.
    // This handles cases like a .SHP file that's actually IFF, or a renamed file.
    if (sniffed != .unknown) return sniffed;

    // Fall back to extension when magic bytes are inconclusive
    // (e.g. SHP and PAK don't always have unique magic signatures)
    if (extensionFormat(filename)) |fmt| return fmt;

    return .unknown;
}

/// Detect format from file extension (case-insensitive).
fn extensionFormat(filename: []const u8) ?FileFormat {
    const basename = std.fs.path.basename(filename);
    const dot_idx = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return null;
    const ext = basename[dot_idx..];
    if (ext.len != 4) return null; // .SHP, .IFF, .PAK are all 4 chars
    if (std.ascii.eqlIgnoreCase(ext, ".shp")) return .shp;
    if (std.ascii.eqlIgnoreCase(ext, ".iff")) return .iff;
    if (std.ascii.eqlIgnoreCase(ext, ".pak")) return .pak;
    return null;
}

/// Detect format from magic bytes in the file data.
fn sniffFormat(data: []const u8) FileFormat {
    // IFF: starts with FORM, CAT , or LIST
    if (data.len >= 4) {
        if (std.mem.eql(u8, data[0..4], "FORM") or
            std.mem.eql(u8, data[0..4], "CAT ") or
            std.mem.eql(u8, data[0..4], "LIST"))
        {
            return .iff;
        }
    }

    // SHP: first 4 bytes = file size (LE), followed by offset table where
    // first offset is >= 8 and (first_offset - 4) % 4 == 0
    if (data.len >= 8) {
        const file_size = std.mem.readInt(u32, data[0..4], .little);
        const first_offset = std.mem.readInt(u32, data[4..8], .little);
        if (file_size > 0 and file_size <= data.len + 16 and
            first_offset >= 8 and first_offset < data.len and
            (first_offset - 4) % 4 == 0)
        {
            // Additional check: first offset should point to valid sprite header area
            if (first_offset + sprite_mod.HEADER_SIZE <= data.len) {
                return .shp;
            }
        }
    }

    // PAK: first 4 bytes = file size, then offset table with E0/C1/FF markers
    if (data.len >= pak_mod.MIN_FILE_SIZE) {
        const file_size = std.mem.readInt(u32, data[0..4], .little);
        if (file_size > 0 and data.len >= 8) {
            const marker = data[7]; // marker byte of first entry
            if (marker == pak_mod.MARKER_DATA or
                marker == pak_mod.MARKER_SUBTABLE or
                marker == pak_mod.MARKER_UNUSED)
            {
                return .pak;
            }
        }
    }

    return .unknown;
}

/// Count sprites in a file based on its detected format.
pub fn countSprites(allocator: std.mem.Allocator, data: []const u8, format: FileFormat) u32 {
    return switch (format) {
        .shp => countShpSprites(allocator, data),
        .iff => countIffSprites(allocator, data),
        .pak => countPakSprites(allocator, data),
        .unknown => 0,
    };
}

fn countShpSprites(allocator: std.mem.Allocator, data: []const u8) u32 {
    var shp = shp_mod.parse(allocator, data) catch return 0;
    defer shp.deinit();
    return @intCast(shp.spriteCount());
}

fn countIffSprites(allocator: std.mem.Allocator, data: []const u8) u32 {
    var result = iff_mod.parseChunk(allocator, data, 0) catch return 0;
    defer result.chunk.deinit();
    const sprites = render_mod.findSprites(allocator, result.chunk) catch return 0;
    defer {
        for (sprites) |*s| {
            var sp = s.*;
            sp.deinit();
        }
        allocator.free(sprites);
    }
    return @intCast(sprites.len);
}

fn countPakSprites(allocator: std.mem.Allocator, data: []const u8) u32 {
    var pak = pak_mod.parse(allocator, data) catch return 0;
    defer pak.deinit();

    var total: u32 = 0;
    for (0..pak.resourceCount()) |i| {
        const res_data = pak.getResource(i) catch continue;
        // Check if resource is an IFF with sprites
        if (res_data.len >= 4 and std.mem.eql(u8, res_data[0..4], "FORM")) {
            total += countIffSprites(allocator, res_data);
        }
        // Check if it's a palette (772 bytes) - skip
        if (res_data.len == pal_mod.PAL_FILE_SIZE) continue;
        // Could also be raw sprite data
        if (res_data.len >= sprite_mod.HEADER_SIZE) {
            const header = sprite_mod.parseHeader(res_data) catch continue;
            const w = header.width() catch continue;
            const h = header.height() catch continue;
            if (w > 0 and h > 0 and w <= 640 and h <= 480) {
                // Looks like a valid sprite - but only count it if we didn't already count IFF sprites
                if (res_data.len < 4 or !std.mem.eql(u8, res_data[0..4], "FORM")) {
                    total += 1;
                }
            }
        }
    }
    return total;
}

/// Decode all sprites from a file. Returns decoded sprites that caller must deinit.
/// If decoding fails with the detected format, tries the other formats as fallback.
pub fn decodeSprites(
    allocator: std.mem.Allocator,
    data: []const u8,
    format: FileFormat,
) ![]sprite_mod.Sprite {
    // Try the detected format first
    if (format != .unknown) {
        if (decodeWithFormat(allocator, data, format)) |sprites| {
            if (sprites.len > 0) return sprites;
            allocator.free(sprites);
        } else |_| {}
    }

    // Fallback: try all other formats
    const fallbacks = [_]FileFormat{ .iff, .shp, .pak };
    for (fallbacks) |fb| {
        if (fb == format) continue;
        if (decodeWithFormat(allocator, data, fb)) |sprites| {
            if (sprites.len > 0) return sprites;
            allocator.free(sprites);
        } else |_| {}
    }

    return error.InvalidFormat;
}

fn decodeWithFormat(
    allocator: std.mem.Allocator,
    data: []const u8,
    format: FileFormat,
) ![]sprite_mod.Sprite {
    return switch (format) {
        .shp => decodeShpSprites(allocator, data),
        .iff => decodeIffSprites(allocator, data),
        .pak => decodePakSprites(allocator, data),
        .unknown => error.InvalidFormat,
    };
}

pub const SpriteViewerError = error{
    InvalidFormat,
    NoSpritesFound,
    PaletteNotFound,
    FileNotFound,
    OutOfMemory,
};

fn decodeShpSprites(allocator: std.mem.Allocator, data: []const u8) ![]sprite_mod.Sprite {
    var shp = try shp_mod.parse(allocator, data);
    defer shp.deinit();

    var sprites: std.ArrayListUnmanaged(sprite_mod.Sprite) = .empty;
    errdefer {
        for (sprites.items) |*s| s.deinit();
        sprites.deinit(allocator);
    }

    for (0..shp.spriteCount()) |i| {
        var s = shp.decodeSprite(allocator, i) catch continue;
        sprites.append(allocator, s) catch {
            s.deinit();
            continue;
        };
    }

    return sprites.toOwnedSlice(allocator);
}

fn decodeIffSprites(allocator: std.mem.Allocator, data: []const u8) ![]sprite_mod.Sprite {
    var result = try iff_mod.parseChunk(allocator, data, 0);
    defer result.chunk.deinit();
    return render_mod.findSprites(allocator, result.chunk);
}

fn decodePakSprites(allocator: std.mem.Allocator, data: []const u8) ![]sprite_mod.Sprite {
    var pak = try pak_mod.parse(allocator, data);
    defer pak.deinit();

    var sprites: std.ArrayListUnmanaged(sprite_mod.Sprite) = .empty;
    errdefer {
        for (sprites.items) |*s| s.deinit();
        sprites.deinit(allocator);
    }

    for (0..pak.resourceCount()) |i| {
        const res_data = pak.getResource(i) catch continue;

        // Try as IFF first
        if (res_data.len >= 4 and std.mem.eql(u8, res_data[0..4], "FORM")) {
            const iff_sprites = decodeIffSprites(allocator, res_data) catch continue;
            defer allocator.free(iff_sprites);
            for (iff_sprites) |s| {
                sprites.append(allocator, s) catch {
                    var sp = s;
                    sp.deinit();
                    continue;
                };
            }
            continue;
        }

        // Skip palettes
        if (res_data.len == pal_mod.PAL_FILE_SIZE) continue;

        // Try as scene pack (offset table + sprites) first
        if (res_data.len >= 8) {
            if (decodeScenePackSprites(allocator, res_data)) |pack_sprites| {
                defer allocator.free(pack_sprites);
                for (pack_sprites) |s| {
                    sprites.append(allocator, s) catch {
                        var sp = s;
                        sp.deinit();
                        continue;
                    };
                }
                continue;
            }
        }

        // Fallback: try as raw sprite
        if (res_data.len >= sprite_mod.HEADER_SIZE) {
            var s = sprite_mod.decode(allocator, res_data) catch continue;
            if (s.width > 0 and s.height > 0 and s.width <= 640 and s.height <= 480) {
                sprites.append(allocator, s) catch {
                    s.deinit();
                    continue;
                };
            } else {
                s.deinit();
            }
        }
    }

    return sprites.toOwnedSlice(allocator);
}

/// Decode all sprites from a scene pack (4-byte size + offset table + sprite data).
fn decodeScenePackSprites(allocator: std.mem.Allocator, data: []const u8) ?[]sprite_mod.Sprite {
    var pack = scene_renderer.parseScenePack(allocator, data) catch return null;
    defer pack.deinit();

    var result: std.ArrayListUnmanaged(sprite_mod.Sprite) = .empty;
    errdefer {
        for (result.items) |*s| s.deinit();
        result.deinit(allocator);
    }

    for (pack.sprite_offsets) |offset| {
        if (offset + sprite_mod.HEADER_SIZE > data.len) continue;
        var s = sprite_mod.decode(allocator, data[offset..]) catch continue;
        if (s.width > 0 and s.height > 0 and s.width <= 640 and s.height <= 480) {
            result.append(allocator, s) catch {
                s.deinit();
                continue;
            };
        } else {
            s.deinit();
        }
    }

    if (result.items.len == 0) {
        result.deinit(allocator);
        return null;
    }
    return result.toOwnedSlice(allocator) catch null;
}

/// Try to find an embedded palette in PAK data (resource 0 if exactly 772 bytes).
pub fn findEmbeddedPalette(allocator: std.mem.Allocator, data: []const u8) ?pal_mod.Palette {
    var pak = pak_mod.parse(allocator, data) catch return null;
    defer pak.deinit();
    if (pak.resourceCount() == 0) return null;
    const res0 = pak.getResource(0) catch return null;
    if (res0.len == pal_mod.PAL_FILE_SIZE) {
        return pal_mod.parse(res0) catch null;
    }
    return null;
}

/// Load the PRIV.TRE data from a GAME.DAT ISO image.
pub fn loadTreFromGameDat(allocator: std.mem.Allocator, game_dat: []const u8) ![]const u8 {
    // Find PRIV.TRE in the ISO image
    const pvd = try iso9660.readPvd(game_dat);
    const root_entries = try iso9660.readDirectory(allocator, game_dat, pvd.root_dir_lba, pvd.root_dir_size);
    defer {
        for (root_entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(root_entries);
    }

    // Find PRIV.TRE in the root directory
    for (root_entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, "PRIV.TRE")) {
            const start = @as(usize, entry.extent_lba) * iso9660.SECTOR_SIZE;
            const end = start + @as(usize, entry.data_size);
            if (end > game_dat.len) return error.FileNotFound;
            return game_dat[start..end];
        }
    }
    return error.FileNotFound;
}

/// Palette used for cockpit and space flight sprites.
pub const SPACE_PALETTE_PATH = "PALETTE/SPACE.PAL";

/// Load a palette: from the given path (TRE or filesystem), or auto-detect
/// based on the source filename context.
pub fn loadPalette(
    allocator: std.mem.Allocator,
    palette_override: ?[]const u8,
    tre_data: ?[]const u8,
    file_data: []const u8,
    format: FileFormat,
) !pal_mod.Palette {
    return loadPaletteForFile(allocator, palette_override, tre_data, file_data, format, null);
}

/// Load a palette with filename context for smarter auto-detection.
pub fn loadPaletteForFile(
    allocator: std.mem.Allocator,
    palette_override: ?[]const u8,
    tre_data: ?[]const u8,
    file_data: []const u8,
    format: FileFormat,
    filename: ?[]const u8,
) !pal_mod.Palette {
    // Priority 1: explicit palette override
    if (palette_override) |pal_path| {
        // Try as filesystem path first
        const pal_data = loadFileFromDisk(allocator, pal_path) catch |err| blk: {
            // Try as TRE path
            if (tre_data) |td| {
                break :blk loadFileFromTre(allocator, td, pal_path) catch return err;
            }
            return err;
        };
        defer allocator.free(pal_data);
        return pal_mod.parse(pal_data);
    }

    // Priority 2: embedded palette (PAK resource 0)
    if (format == .pak) {
        if (findEmbeddedPalette(allocator, file_data)) |pal| return pal;
    }

    // Priority 3: context-based palette from TRE (cockpits use SPACE.PAL)
    if (tre_data) |td| {
        if (filename) |name| {
            const context_pal = inferPalettePath(name);
            if (!std.mem.eql(u8, context_pal, DEFAULT_PALETTE_PATH)) {
                if (loadFileFromTre(allocator, td, context_pal)) |pal_data| {
                    defer allocator.free(pal_data);
                    return pal_mod.parse(pal_data);
                } else |_| {}
            }
        }

        // Priority 4: default palette from TRE
        const pal_data = loadFileFromTre(allocator, td, DEFAULT_PALETTE_PATH) catch
            return SpriteViewerError.PaletteNotFound;
        defer allocator.free(pal_data);
        return pal_mod.parse(pal_data);
    }

    return SpriteViewerError.PaletteNotFound;
}

/// Infer the best palette for a file based on its TRE path.
fn inferPalettePath(filename: []const u8) []const u8 {
    // Cockpit files use the space flight palette
    if (containsIgnoreCase(filename, "COCKPIT") or containsIgnoreCase(filename, "CK.IFF") or
        containsIgnoreCase(filename, "CK.PAK"))
    {
        return SPACE_PALETTE_PATH;
    }
    // Ships/space objects also use space palette
    if (containsIgnoreCase(filename, "SHIP") or containsIgnoreCase(filename, "APPEARNC")) {
        return SPACE_PALETTE_PATH;
    }
    return DEFAULT_PALETTE_PATH;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Load a file from disk.
fn loadFileFromDisk(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const data = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(data);
    const bytes_read = try file.readAll(data);
    if (bytes_read != stat.size) return error.FileNotFound;
    return data;
}

/// Load a file from the TRE archive by normalized path (e.g. "PALETTE/PCMAIN.PAL").
fn loadFileFromTre(allocator: std.mem.Allocator, tre_data: []const u8, path: []const u8) ![]u8 {
    const header = try tre.readHeader(tre_data);
    for (0..header.entry_count) |i| {
        var entry = try tre.readEntry(allocator, tre_data, @intCast(i));
        defer entry.deinit();

        // Normalize the TRE entry path and compare
        const normalized = normalizeTrePath(entry.path) orelse continue;
        if (std.ascii.eqlIgnoreCase(normalized, path)) {
            const file_data = try tre.extractFileData(tre_data, entry.offset, entry.size);
            const result = try allocator.dupe(u8, file_data);
            return result;
        }
    }
    return error.FileNotFound;
}

/// Normalize a TRE entry path (strip DATA/ prefix).
pub fn normalizeTrePath(path: []const u8) ?[]const u8 {
    // Find DATA/ or DATA\ prefix
    if (std.mem.indexOf(u8, path, "DATA/")) |idx| {
        return path[idx + 5 ..];
    }
    if (std.mem.indexOf(u8, path, "DATA\\")) |idx| {
        return path[idx + 5 ..];
    }
    // Already clean path
    return path;
}

/// List all sprite-containing files in the TRE archive.
pub fn listSpriteFiles(
    allocator: std.mem.Allocator,
    tre_data: []const u8,
) ![]SpriteFileInfo {
    const header = try tre.readHeader(tre_data);
    var results: std.ArrayListUnmanaged(SpriteFileInfo) = .empty;
    errdefer {
        for (results.items) |item| {
            allocator.free(item.path);
        }
        results.deinit(allocator);
    }

    for (0..header.entry_count) |i| {
        var entry = try tre.readEntry(allocator, tre_data, @intCast(i));

        const normalized_opt = normalizeTrePath(entry.path);
        if (normalized_opt == null) {
            entry.deinit();
            continue;
        }
        const normalized = normalized_opt.?;

        // Get file data
        const file_data = tre.extractFileData(tre_data, entry.offset, entry.size) catch {
            entry.deinit();
            continue;
        };

        const format = detectFormat(entry.path, file_data);

        if (format == .unknown) {
            entry.deinit();
            continue;
        }

        const sprite_count = countSprites(allocator, file_data, format);
        if (sprite_count == 0) {
            entry.deinit();
            continue;
        }

        const path_copy = allocator.dupe(u8, normalized) catch {
            entry.deinit();
            continue;
        };

        try results.append(allocator, .{
            .path = path_copy,
            .format = format,
            .sprite_count = sprite_count,
        });

        entry.deinit();
    }

    return results.toOwnedSlice(allocator);
}

/// Format name for display.
pub fn formatName(format: FileFormat) []const u8 {
    return switch (format) {
        .shp => "SHP",
        .iff => "IFF",
        .pak => "PAK",
        .unknown => "???",
    };
}

// --- Tests ---

test "detectFormat identifies SHP by extension" {
    const data = [_]u8{0} ** 16;
    try std.testing.expectEqual(FileFormat.shp, detectFormat("PCFONT.SHP", &data));
    try std.testing.expectEqual(FileFormat.shp, detectFormat("test.shp", &data));
}

test "detectFormat identifies IFF by extension" {
    const data = [_]u8{0} ** 16;
    try std.testing.expectEqual(FileFormat.iff, detectFormat("ATTITUDE.IFF", &data));
}

test "detectFormat identifies PAK by extension" {
    const data = [_]u8{0} ** 16;
    try std.testing.expectEqual(FileFormat.pak, detectFormat("CLUNKCK.PAK", &data));
}

test "detectFormat trusts magic bytes over wrong extension" {
    // File named .SHP but data starts with FORM (IFF magic)
    var data: [16]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], "FORM");
    try std.testing.expectEqual(FileFormat.iff, detectFormat("misnamed.SHP", &data));
}

test "sniffFormat detects IFF by FORM magic" {
    var data: [16]u8 = undefined;
    @memcpy(data[0..4], "FORM");
    try std.testing.expectEqual(FileFormat.iff, sniffFormat(&data));
}

test "sniffFormat detects IFF by CAT magic" {
    var data: [16]u8 = undefined;
    @memcpy(data[0..4], "CAT ");
    try std.testing.expectEqual(FileFormat.iff, sniffFormat(&data));
}

test "sniffFormat returns unknown for unrecognized data" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF } ++ [_]u8{0} ** 12;
    try std.testing.expectEqual(FileFormat.unknown, sniffFormat(&data));
}

test "formatName returns correct strings" {
    try std.testing.expectEqualStrings("SHP", formatName(.shp));
    try std.testing.expectEqualStrings("IFF", formatName(.iff));
    try std.testing.expectEqualStrings("PAK", formatName(.pak));
    try std.testing.expectEqualStrings("???", formatName(.unknown));
}

test "normalizeTrePath strips DATA/ prefix" {
    const result = normalizeTrePath("../../DATA/FONTS/PCFONT.SHP");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("FONTS/PCFONT.SHP", result.?);
}

test "normalizeTrePath handles clean paths" {
    const result = normalizeTrePath("FONTS/PCFONT.SHP");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("FONTS/PCFONT.SHP", result.?);
}

test "extensionFormat detects known extensions" {
    try std.testing.expectEqual(@as(?FileFormat, .shp), extensionFormat("test.SHP"));
    try std.testing.expectEqual(@as(?FileFormat, .iff), extensionFormat("test.IFF"));
    try std.testing.expectEqual(@as(?FileFormat, .pak), extensionFormat("test.PAK"));
    try std.testing.expectEqual(@as(?FileFormat, null), extensionFormat("test.txt"));
}

test "findEmbeddedPalette returns null for non-PAK data" {
    const data = [_]u8{0} ** 16;
    try std.testing.expectEqual(@as(?pal_mod.Palette, null), findEmbeddedPalette(std.testing.allocator, &data));
}

test "sprite_viewer module loads" {
    try std.testing.expect(true);
}
