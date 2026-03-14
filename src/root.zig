//! Privateer - Wing Commander: Privateer reimplementation
//! Core engine library root module.

const std = @import("std");

pub const testing_helpers = @import("testing.zig");
pub const sdl = @import("sdl.zig");
pub const config = @import("config.zig");

test "engine module loads" {
    try std.testing.expect(true);
}

test {
    // Pull in tests from all submodules
    std.testing.refAllDecls(@This());
}
