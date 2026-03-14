const std = @import("std");
const privateer = @import("privateer");

pub fn main() !void {
    std.debug.print("Privateer engine starting...\n", .{});
}

test "main module loads engine" {
    _ = privateer;
    try std.testing.expect(true);
}
