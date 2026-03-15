//! Asset repacking CLI tool for Wing Commander: Privateer.
//! Builds a GAME.DAT (ISO 9660 + PRIV.TRE) from a directory of extracted assets.
//!
//! Usage: privateer-repack --input <extracted-dir> --output <GAME.DAT>

const std = @import("std");
const privateer = @import("privateer");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var input_dir: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (i + 1 < args.len) {
            if (std.mem.eql(u8, args[i], "--input")) {
                input_dir = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--output")) {
                output_path = args[i + 1];
                i += 1;
            }
        }
    }

    const input = input_dir orelse {
        std.debug.print("Usage: privateer-repack --input <extracted-dir> --output <GAME.DAT>\n", .{});
        std.debug.print("  --input   Directory containing extracted game assets\n", .{});
        std.debug.print("  --output  Output GAME.DAT file path\n", .{});
        std.process.exit(1);
    };

    const output = output_path orelse {
        std.debug.print("Error: --output is required\n", .{});
        std.process.exit(1);
    };

    std.debug.print("Repacking {s} → {s}...\n", .{ input, output });

    const result = privateer.repack.repackAll(allocator, input, output) catch |err| {
        std.debug.print("Error: repack failed: {}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("\nRepack complete:\n", .{});
    std.debug.print("  Files packed:  {}\n", .{result.files_packed});
    std.debug.print("  Bytes written: {}\n", .{result.bytes_written});
}

test "repack_cli module loads" {
    try std.testing.expect(true);
}
