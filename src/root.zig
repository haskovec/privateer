//! Privateer - Wing Commander: Privateer reimplementation
//! Core engine library root module.

const std = @import("std");

pub const testing_helpers = @import("testing.zig");
pub const sdl = @import("sdl.zig");
pub const config = @import("config.zig");
pub const iso9660 = @import("iso9660.zig");
pub const tre = @import("tre.zig");
pub const iff = @import("iff.zig");
pub const pal = @import("pal.zig");
pub const sprite = @import("sprite.zig");
pub const shp = @import("shp.zig");
pub const pak = @import("pak.zig");
pub const integration_tests = @import("integration_tests.zig");

test "engine module loads" {
    try std.testing.expect(true);
}

test {
    // Pull in tests from all submodules
    std.testing.refAllDecls(@This());
}
