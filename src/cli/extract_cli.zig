//! Asset extraction CLI tool for Wing Commander: Privateer.
//! Extracts all 832 files from GAME.DAT (ISO 9660 → PRIV.TRE) to a directory tree.
//!
//! Usage: privateer-extract [--data-dir <path>] --output <dir>
//!
//! The --data-dir flag is optional if data_dir is set in privateer.json
//! or via the PRIVATEER_DATA environment variable.

const std = @import("std");
const privateer = @import("privateer");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // Parse command-line arguments
    const argv = try init.minimal.args.toSlice(arena);
    const args = try privateer.config.argSlices(arena, argv);

    // Resolve data_dir from config file / env var / CLI args
    var cfg = privateer.config.resolveForCli(io, init.minimal.environ, allocator, args[1..]) catch {
        std.debug.print("Error: could not resolve config. Use --data-dir or set data_dir in privateer.json\n", .{});
        std.process.exit(1);
    };
    defer cfg.deinit();

    const data_path = cfg.data_dir;

    // Parse --output manually (extract-specific)
    var output_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (i + 1 < args.len and std.mem.eql(u8, args[i], "--output")) {
            output_dir = args[i + 1];
            i += 1;
        }
    }

    const out_path = output_dir orelse {
        std.debug.print("Usage: privateer-extract [--data-dir <path>] --output <output-dir>\n", .{});
        std.debug.print("  --data-dir  Directory containing GAME.DAT (optional if set in privateer.json or PRIVATEER_DATA)\n", .{});
        std.debug.print("  --output    Directory to extract files to\n", .{});
        std.process.exit(1);
    };

    // Build path to GAME.DAT
    const game_dat_path = try std.fmt.allocPrint(allocator, "{s}/GAME.DAT", .{data_path});
    defer allocator.free(game_dat_path);

    std.debug.print("Loading {s}...\n", .{game_dat_path});

    // Load GAME.DAT
    const data = std.Io.Dir.cwd().readFileAlloc(io, game_dat_path, allocator, .unlimited) catch |err| {
        std.debug.print("Error: could not read {s}: {}\n", .{ game_dat_path, err });
        std.process.exit(1);
    };
    defer allocator.free(data);

    std.debug.print("GAME.DAT size: {} bytes\n", .{data.len});

    // Create output directory
    std.Io.Dir.cwd().createDirPath(io, out_path) catch |err| {
        std.debug.print("Error: could not create output directory {s}: {}\n", .{ out_path, err });
        std.process.exit(1);
    };

    std.debug.print("Extracting to {s}...\n", .{out_path});

    // Run extraction
    const result = try privateer.extract.extractAll(allocator, io, data, out_path);

    std.debug.print("\nExtraction complete:\n", .{});
    std.debug.print("  Files extracted: {}\n", .{result.files_extracted});
    std.debug.print("  Files failed:    {}\n", .{result.files_failed});
    std.debug.print("  Bytes written:   {}\n", .{result.bytes_written});
}

test "extract_cli module loads" {
    try std.testing.expect(true);
}
