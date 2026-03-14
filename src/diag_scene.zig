//! Diagnostic: explore scene background data in real game files.
//! This is a temporary exploration tool, not part of the engine.

const std = @import("std");
const iso9660 = @import("iso9660.zig");
const tre = @import("tre.zig");
const pak = @import("pak.zig");
const pal = @import("pal.zig");
const sprite = @import("sprite.zig");

const GAME_DATA_DIR = "C:\\Program Files\\EA Games\\Wing Commander Privateer\\DATA";
const GAME_DAT_PATH = GAME_DATA_DIR ++ "\\GAME.DAT";

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

fn loadTreData(allocator: std.mem.Allocator) !?struct { data: []const u8, tre_data: []const u8 } {
    const data = try loadGameDat(allocator) orelse return null;
    errdefer allocator.free(data);
    const pvd = try iso9660.readPvd(data);
    const tre_info = try iso9660.findFile(allocator, data, pvd, "PRIV.TRE");
    const tre_data = try iso9660.readFileData(data, tre_info.lba, tre_info.size);
    return .{ .data = data, .tre_data = tre_data };
}

test "diag: decode PAK resources as sprites" {
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

    std.debug.print("\n=== PAK Resource Sprite Decode Test ===\n", .{});

    // Test a few specific PAK files
    const test_paks = [_][]const u8{
        "OPTSHPS.PAK",
        "CU.PAK",
        "MID1.PAK",
        "LANDINGS.PAK",
        "CUBICLE.PAK",
    };

    for (test_paks) |pak_name| {
        var entry = tre.findEntry(allocator, loaded.tre_data, pak_name) catch continue;
        defer entry.deinit();

        const file_data = try tre.extractFileData(loaded.tre_data, entry.offset, entry.size);
        var pak_file = pak.parse(allocator, file_data) catch continue;
        defer pak_file.deinit();

        std.debug.print("\n--- {s} ({} resources) ---\n", .{ pak_name, pak_file.resourceCount() });

        for (0..@min(pak_file.resourceCount(), 6)) |i| {
            const resource = pak_file.getResource(i) catch continue;

            // Check if this is a palette (772 bytes)
            if (resource.len == pal.PAL_FILE_SIZE) {
                const palette = pal.parse(resource) catch {
                    std.debug.print("  Resource {}: {} bytes - looks like palette but failed to parse\n", .{ i, resource.len });
                    continue;
                };
                _ = palette;
                std.debug.print("  Resource {}: PALETTE (772 bytes)\n", .{i});
                continue;
            }

            if (resource.len < 12) {
                std.debug.print("  Resource {}: {} bytes (too small)\n", .{ i, resource.len });
                continue;
            }

            // Parse first 4 bytes as size, next 4 as first offset
            const res_size = std.mem.readInt(u32, resource[0..4], .little);
            const first_offset = std.mem.readInt(u32, resource[4..8], .little);

            std.debug.print("  Resource {}: {} bytes, declared_size={}, first_offset={}\n", .{ i, resource.len, res_size, first_offset });

            // Count offsets in the table (from byte 4 to first_offset)
            if (first_offset >= 8 and first_offset < resource.len) {
                const num_offsets = (first_offset - 4) / 4;
                std.debug.print("    offset_table: {} entries [", .{num_offsets});
                for (0..@min(num_offsets, 8)) |j| {
                    const off = std.mem.readInt(u32, resource[4 + j * 4 ..][0..4], .little);
                    std.debug.print("{} ", .{off});
                }
                if (num_offsets > 8) std.debug.print("...", .{});
                std.debug.print("]\n", .{});

                // Try to decode sprite at first offset
                if (first_offset + sprite.HEADER_SIZE <= resource.len) {
                    const sprite_data = resource[first_offset..];
                    var spr = sprite.decode(allocator, sprite_data) catch |err| {
                        std.debug.print("    sprite decode failed: {}\n", .{err});
                        continue;
                    };
                    defer spr.deinit();
                    std.debug.print("    sprite: {}x{} (x2={}, x1={}, y1={}, y2={}), pixels={}\n", .{
                        spr.width,             spr.height,
                        spr.header.x2,         spr.header.x1,
                        spr.header.y1,         spr.header.y2,
                        spr.pixels.len,
                    });

                    // Check if it has non-zero pixels
                    var non_zero: usize = 0;
                    for (spr.pixels) |p| {
                        if (p != 0) non_zero += 1;
                    }
                    std.debug.print("    non-zero pixels: {} / {} ({d:.1}%)\n", .{
                        non_zero,
                        spr.pixels.len,
                        @as(f64, @floatFromInt(non_zero)) / @as(f64, @floatFromInt(spr.pixels.len)) * 100.0,
                    });
                }
            }
        }
    }
}
