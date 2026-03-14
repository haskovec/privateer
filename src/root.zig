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
pub const voc = @import("voc.zig");
pub const vpk = @import("vpk.zig");
pub const music = @import("music.zig");
pub const png = @import("png.zig");
pub const render = @import("render.zig");
pub const palette_viewer = @import("palette_viewer.zig");
pub const validate = @import("validate.zig");
pub const window = @import("window.zig");
pub const framebuffer = @import("framebuffer.zig");
pub const upscale = @import("upscale.zig");
pub const viewport = @import("viewport.zig");
pub const text = @import("text.zig");
pub const extract = @import("extract.zig");
pub const integration_tests = @import("integration_tests.zig");

test "engine module loads" {
    try std.testing.expect(true);
}

test {
    // Pull in tests from all submodules
    std.testing.refAllDecls(@This());
}
