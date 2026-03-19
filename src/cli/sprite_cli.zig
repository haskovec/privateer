//! Sprite viewer CLI tool for Wing Commander: Privateer.
//! Lists and displays sprites from GAME.DAT or extracted files, with
//! inline terminal display via the Kitty graphics protocol and PNG export.
//!
//! Usage:
//!   privateer-sprite list --data-dir <path>
//!   privateer-sprite view --data-dir <path> --file <tre-path> [options]
//!   privateer-sprite view --input <file> [options]
//!
//! Options:
//!   --palette <path>     Override palette (TRE path or filesystem path)
//!   --index <n>          Show only sprite N (default: show all)
//!   --scale <1|2|3|4>    Scale factor (default: 1 = original)
//!   --side-by-side       Show original and upscaled side by side
//!   --save <path.png>    Save sprite as PNG file
//!   --no-inline          Skip inline terminal display

const std = @import("std");
const privateer = @import("privateer");

const sprite_viewer = privateer.sprite_viewer;
const sprite_mod = privateer.sprite;
const pal_mod = privateer.pal;
const render_mod = privateer.render;
const png_mod = privateer.png;
const upscale_mod = privateer.upscale;
const kitty = privateer.kitty_graphics;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const subcommand = args[1];

    if (std.mem.eql(u8, subcommand, "list")) {
        try runList(allocator, args[2..]);
    } else if (std.mem.eql(u8, subcommand, "view")) {
        try runView(allocator, args[2..]);
    } else if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown subcommand: {s}\n\n", .{subcommand});
        printUsage();
        std.process.exit(1);
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: privateer-sprite <command> [options]
        \\
        \\Commands:
        \\  list    List all sprite-containing files in GAME.DAT
        \\  view    View sprites inline or save as PNG
        \\
        \\List options:
        \\  --data-dir <path>    Directory containing GAME.DAT
        \\
        \\View options:
        \\  --data-dir <path>    Directory containing GAME.DAT (for TRE access)
        \\  --file <tre-path>    File path within TRE (e.g. FONTS/PCFONT.SHP)
        \\  --input <file>       Path to an extracted file on disk
        \\  --palette <path>     Override palette (TRE path or filesystem path)
        \\  --index <n>          Show only sprite at index N (default: all)
        \\  --scale <1|2|3|4>    Upscale factor (default: 1)
        \\  --side-by-side       Show original and upscaled side by side
        \\  --save <path.png>    Save sprite(s) as PNG file(s)
        \\  --no-inline          Skip inline terminal display
        \\
    , .{});
}

/// Parsed CLI arguments for the view subcommand.
const ViewArgs = struct {
    data_dir: ?[]const u8 = null,
    tre_file: ?[]const u8 = null,
    input_file: ?[]const u8 = null,
    palette: ?[]const u8 = null,
    index: ?usize = null,
    scale: u8 = 1,
    side_by_side: bool = false,
    save_path: ?[]const u8 = null,
    no_inline: bool = false,
};

fn parseViewArgs(args: []const [:0]const u8) ViewArgs {
    var result = ViewArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (i + 1 < args.len) {
            if (std.mem.eql(u8, args[i], "--data-dir")) {
                result.data_dir = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--file")) {
                result.tre_file = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--input")) {
                result.input_file = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--palette")) {
                result.palette = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--index")) {
                result.index = std.fmt.parseInt(usize, args[i + 1], 10) catch null;
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--scale")) {
                result.scale = std.fmt.parseInt(u8, args[i + 1], 10) catch 1;
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--save")) {
                result.save_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--side-by-side")) {
                result.side_by_side = true;
            } else if (std.mem.eql(u8, args[i], "--no-inline")) {
                result.no_inline = true;
            }
        } else {
            if (std.mem.eql(u8, args[i], "--side-by-side")) {
                result.side_by_side = true;
            } else if (std.mem.eql(u8, args[i], "--no-inline")) {
                result.no_inline = true;
            }
        }
    }
    return result;
}

fn runList(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    var data_dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (i + 1 < args.len and std.mem.eql(u8, args[i], "--data-dir")) {
            data_dir = args[i + 1];
            i += 1;
        }
    }

    const data_path = data_dir orelse {
        std.debug.print("Error: --data-dir is required for list command\n", .{});
        std.process.exit(1);
    };

    // Load GAME.DAT
    const game_dat_path = try std.fmt.allocPrint(allocator, "{s}/GAME.DAT", .{data_path});
    defer allocator.free(game_dat_path);

    std.debug.print("Loading {s}...\n", .{game_dat_path});

    const game_dat = loadFile(allocator, game_dat_path) catch {
        std.debug.print("Error: could not open {s}\n", .{game_dat_path});
        std.process.exit(1);
    };
    defer allocator.free(game_dat);

    // Extract TRE from ISO
    const tre_data = sprite_viewer.loadTreFromGameDat(allocator, game_dat) catch {
        std.debug.print("Error: could not find PRIV.TRE in GAME.DAT\n", .{});
        std.process.exit(1);
    };

    std.debug.print("Scanning for sprite files...\n\n", .{});

    const files = try sprite_viewer.listSpriteFiles(allocator, tre_data);
    defer {
        for (files) |f| allocator.free(f.path);
        allocator.free(files);
    }

    // Print header
    std.debug.print("{s:<40} {s:<6} {s:>8}\n", .{ "PATH", "FORMAT", "SPRITES" });
    std.debug.print("{s:-<40} {s:-<6} {s:->8}\n", .{ "", "", "" });

    for (files) |f| {
        std.debug.print("{s:<40} {s:<6} {d:>8}\n", .{
            f.path,
            sprite_viewer.formatName(f.format),
            f.sprite_count,
        });
    }

    std.debug.print("\nTotal: {} sprite-containing files\n", .{files.len});
}

fn runView(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    const view_args = parseViewArgs(args);

    if (view_args.input_file == null and (view_args.data_dir == null or view_args.tre_file == null)) {
        std.debug.print("Error: either --input <file> or --data-dir + --file are required\n", .{});
        std.process.exit(1);
    }

    // Validate scale factor
    if (view_args.scale != 1 and view_args.scale != 2 and view_args.scale != 3 and view_args.scale != 4) {
        std.debug.print("Error: --scale must be 1, 2, 3, or 4\n", .{});
        std.process.exit(1);
    }

    // Load sprite data
    var file_data: []u8 = undefined;
    var tre_data_opt: ?[]const u8 = null;
    var game_dat: ?[]u8 = null;
    var filename: []const u8 = undefined;

    if (view_args.input_file) |input_path| {
        file_data = loadFile(allocator, input_path) catch {
            std.debug.print("Error: could not open {s}\n", .{input_path});
            std.process.exit(1);
        };
        filename = input_path;

        // Also load TRE if data-dir specified (for palette access)
        if (view_args.data_dir) |data_path| {
            const gd_path = try std.fmt.allocPrint(allocator, "{s}/GAME.DAT", .{data_path});
            defer allocator.free(gd_path);
            game_dat = loadFile(allocator, gd_path) catch null;
            if (game_dat) |gd| {
                tre_data_opt = sprite_viewer.loadTreFromGameDat(allocator, gd) catch null;
            }
        }
    } else {
        // Load from TRE
        const data_path = view_args.data_dir.?;
        const gd_path = try std.fmt.allocPrint(allocator, "{s}/GAME.DAT", .{data_path});
        defer allocator.free(gd_path);

        game_dat = loadFile(allocator, gd_path) catch {
            std.debug.print("Error: could not open {s}\n", .{gd_path});
            std.process.exit(1);
        };

        const tre_data = sprite_viewer.loadTreFromGameDat(allocator, game_dat.?) catch {
            std.debug.print("Error: could not find PRIV.TRE in GAME.DAT\n", .{});
            std.process.exit(1);
        };
        tre_data_opt = tre_data;

        const tre_file = view_args.tre_file.?;
        filename = tre_file;

        // Find and load the file from TRE
        const header = try privateer.tre.readHeader(tre_data);
        var found = false;
        for (0..header.entry_count) |idx| {
            var entry = try privateer.tre.readEntry(allocator, tre_data, @intCast(idx));
            defer entry.deinit();

            const normalized = sprite_viewer.normalizeTrePath(entry.path) orelse continue;
            if (std.ascii.eqlIgnoreCase(normalized, tre_file)) {
                const raw = try privateer.tre.extractFileData(tre_data, entry.offset, entry.size);
                file_data = try allocator.dupe(u8, raw);
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("Error: file not found in TRE: {s}\n", .{tre_file});
            std.process.exit(1);
        }
    }
    defer allocator.free(file_data);
    defer if (game_dat) |gd| allocator.free(gd);

    // Detect format
    const format = sprite_viewer.detectFormat(filename, file_data);
    if (format == .unknown) {
        std.debug.print("Error: unrecognized sprite format for {s}\n", .{filename});
        std.process.exit(1);
    }

    // Load palette
    const palette = sprite_viewer.loadPalette(
        allocator,
        view_args.palette,
        tre_data_opt,
        file_data,
        format,
    ) catch {
        std.debug.print("Error: could not load palette. Use --palette to specify one.\n", .{});
        std.process.exit(1);
    };

    // Decode sprites
    const sprites = sprite_viewer.decodeSprites(allocator, file_data, format) catch {
        std.debug.print("Error: no sprites could be decoded from {s}\n", .{filename});
        std.process.exit(1);
    };
    defer {
        for (sprites) |*s| s.deinit();
        allocator.free(sprites);
    }

    if (sprites.len == 0) {
        std.debug.print("No sprites found in {s}\n", .{filename});
        return;
    }

    std.debug.print("Found {} sprite(s) in {s}\n\n", .{ sprites.len, filename });

    // Detect terminal capabilities for inline display
    const kitty_supported = kitty.isKittySupported();
    const can_inline = !view_args.no_inline and kitty_supported;

    // If no Kitty support and no --save path, auto-save to PNG files
    const auto_save = !kitty_supported and !view_args.no_inline and view_args.save_path == null;
    if (auto_save) {
        std.debug.print("Terminal does not support Kitty graphics protocol.\n", .{});
        std.debug.print("Saving sprites as PNG files instead.\n\n", .{});
    } else if (!kitty_supported and !view_args.no_inline and view_args.save_path != null) {
        std.debug.print("Terminal does not support Kitty graphics protocol; using --save output only.\n\n", .{});
    }

    // Determine which sprites to show
    const start_idx: usize = if (view_args.index) |idx| @min(idx, sprites.len - 1) else 0;
    const end_idx: usize = if (view_args.index) |idx| @min(idx + 1, sprites.len) else sprites.len;

    const stdout_writer = std.fs.File.stdout().deprecatedWriter();

    for (start_idx..end_idx) |idx| {
        const spr = sprites[idx];
        std.debug.print("Sprite {}/{}: {}x{}\n", .{ idx, sprites.len, spr.width, spr.height });

        // Convert to RGBA
        var rgba_image = try render_mod.spriteToRgba(allocator, spr, palette);
        defer rgba_image.deinit();

        // Determine the effective save path: explicit --save, or auto-generated
        const effective_save = if (view_args.save_path) |p|
            p
        else if (auto_save)
            "sprite.png"
        else
            @as(?[]const u8, null);

        if (view_args.scale > 1 and view_args.side_by_side) {
            // Side-by-side: original + upscaled
            const factor = scaleToFactor(view_args.scale);
            var upscaled = try upscale_mod.upscale(
                allocator,
                rgba_image.pixels,
                rgba_image.width,
                rgba_image.height,
                factor,
            );
            defer upscaled.deinit();

            var composite = try kitty.compositeSideBySide(
                allocator,
                rgba_image.pixels,
                rgba_image.width,
                rgba_image.height,
                upscaled.pixels,
                upscaled.width,
                upscaled.height,
                8, // 8px gap
            );
            defer composite.deinit();

            if (can_inline) {
                std.debug.print("  [1x: {}x{}]  |  [{}x: {}x{}]\n", .{
                    rgba_image.width, rgba_image.height,
                    view_args.scale,   upscaled.width,  upscaled.height,
                });
                try kitty.displayImage(stdout_writer, allocator, composite.pixels, composite.width, composite.height);
            }

            if (effective_save) |base_path| {
                try savePng(allocator, base_path, idx, sprites.len, composite.pixels, composite.width, composite.height);
            }
        } else if (view_args.scale > 1) {
            // Upscaled only
            const factor = scaleToFactor(view_args.scale);
            var upscaled = try upscale_mod.upscale(
                allocator,
                rgba_image.pixels,
                rgba_image.width,
                rgba_image.height,
                factor,
            );
            defer upscaled.deinit();

            if (can_inline) {
                try kitty.displayImage(stdout_writer, allocator, upscaled.pixels, upscaled.width, upscaled.height);
            }

            if (effective_save) |base_path| {
                try savePng(allocator, base_path, idx, sprites.len, upscaled.pixels, upscaled.width, upscaled.height);
            }
        } else {
            // Original size
            if (can_inline) {
                try kitty.displayImage(stdout_writer, allocator, rgba_image.pixels, rgba_image.width, rgba_image.height);
            }

            if (effective_save) |base_path| {
                try savePng(allocator, base_path, idx, sprites.len, rgba_image.pixels, rgba_image.width, rgba_image.height);
            }
        }
    }
}

fn scaleToFactor(scale: u8) upscale_mod.ScaleFactor {
    return switch (scale) {
        2 => .x2,
        3 => .x3,
        4 => .x4,
        else => .x2,
    };
}


fn savePng(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    index: usize,
    total: usize,
    pixels: []const u8,
    width: u32,
    height: u32,
) !void {
    // If multiple sprites, append index to filename
    const save_path = if (total > 1) blk: {
        // Insert index before .png extension
        const dot_idx = std.mem.lastIndexOfScalar(u8, base_path, '.') orelse base_path.len;
        break :blk try std.fmt.allocPrint(allocator, "{s}_{d}{s}", .{
            base_path[0..dot_idx],
            index,
            base_path[dot_idx..],
        });
    } else try allocator.dupe(u8, base_path);
    defer allocator.free(save_path);

    const png_data = try png_mod.encode(allocator, width, height, pixels);
    defer allocator.free(png_data);

    const file = try std.fs.cwd().createFile(save_path, .{});
    defer file.close();
    try file.writeAll(png_data);

    std.debug.print("  Saved: {s}\n", .{save_path});
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const data = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(data);
    const bytes_read = try file.readAll(data);
    if (bytes_read != stat.size) {
        allocator.free(data);
        return error.FileNotFound;
    }
    return data;
}

// Expose normalizeTrePath for use by other modules
pub const normalizeTrePath = sprite_viewer.normalizeTrePath;

test "sprite_cli module loads" {
    try std.testing.expect(true);
}
