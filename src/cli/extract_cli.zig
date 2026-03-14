//! Asset extraction CLI tool for Wing Commander: Privateer.
//! Extracts all 832 files from GAME.DAT (ISO 9660 → PRIV.TRE) to a directory tree.
//!
//! Usage: privateer-extract --data-dir <path> --output <dir>

const std = @import("std");
const privateer = @import("privateer");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var data_dir: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;

    var i: usize = 1; // skip program name
    while (i < args.len) : (i += 1) {
        if (i + 1 < args.len) {
            if (std.mem.eql(u8, args[i], "--data-dir")) {
                data_dir = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--output")) {
                output_dir = args[i + 1];
                i += 1;
            }
        }
    }

    const data_path = data_dir orelse {
        std.debug.print("Usage: privateer-extract --data-dir <path-to-GAME.DAT-directory> --output <output-dir>\n", .{});
        std.debug.print("  --data-dir  Directory containing GAME.DAT\n", .{});
        std.debug.print("  --output    Directory to extract files to\n", .{});
        std.process.exit(1);
    };

    const out_path = output_dir orelse {
        std.debug.print("Error: --output is required\n", .{});
        std.process.exit(1);
    };

    // Build path to GAME.DAT
    const game_dat_path = try std.fmt.allocPrint(allocator, "{s}/GAME.DAT", .{data_path});
    defer allocator.free(game_dat_path);

    std.debug.print("Loading {s}...\n", .{game_dat_path});

    // Load GAME.DAT
    const file = std.fs.cwd().openFile(game_dat_path, .{}) catch |err| {
        std.debug.print("Error: could not open {s}: {}\n", .{ game_dat_path, err });
        std.process.exit(1);
    };
    defer file.close();

    const stat = try file.stat();
    std.debug.print("GAME.DAT size: {} bytes\n", .{stat.size});

    const data = try allocator.alloc(u8, stat.size);
    defer allocator.free(data);

    const bytes_read = try file.readAll(data);
    if (bytes_read != stat.size) {
        std.debug.print("Error: incomplete read of GAME.DAT\n", .{});
        std.process.exit(1);
    }

    // Create output directory
    std.fs.cwd().makePath(out_path) catch |err| {
        std.debug.print("Error: could not create output directory {s}: {}\n", .{ out_path, err });
        std.process.exit(1);
    };

    std.debug.print("Extracting to {s}...\n", .{out_path});

    // Run extraction
    const result = try privateer.extract.extractAll(allocator, data, out_path);

    std.debug.print("\nExtraction complete:\n", .{});
    std.debug.print("  Files extracted: {}\n", .{result.files_extracted});
    std.debug.print("  Files failed:    {}\n", .{result.files_failed});
    std.debug.print("  Bytes written:   {}\n", .{result.bytes_written});
}

test "extract_cli module loads" {
    try std.testing.expect(true);
}
