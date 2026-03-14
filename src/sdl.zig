//! SDL3 initialization and shutdown wrapper.
//! Provides a safe Zig interface for SDL3 lifecycle management.

const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const InitError = error{
    SdlInitFailed,
};

/// Initialize SDL3 with video and audio subsystems.
pub fn init() InitError!void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO)) {
        std.log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return InitError.SdlInitFailed;
    }
}

/// Shut down SDL3 and release all resources.
pub fn shutdown() void {
    c.SDL_Quit();
}

/// Re-export SDL C bindings for direct access when needed.
pub const raw = c;

// --- Tests ---

test "SDL3 initializes and shuts down without error" {
    try init();
    defer shutdown();
}

test "SDL3 version is available" {
    const version = c.SDL_GetVersion();
    // SDL3 versions start at 3.x
    try std.testing.expect(version >= 3000000);
}
