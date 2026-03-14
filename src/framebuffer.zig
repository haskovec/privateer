//! Palette-based software renderer.
//! Maintains a 320x200 8-bit indexed color framebuffer, converts to RGBA
//! via palette lookup, and uploads to an SDL3 streaming texture for display.
//!
//! The original game renders at 320x200 with 256-color palettes. This module
//! replicates that pipeline: indexed pixels → palette lookup → RGBA → SDL texture.

const std = @import("std");
const sdl = @import("sdl.zig");
const c = sdl.raw;
const pal = @import("pal.zig");
const window_mod = @import("window.zig");

/// Internal framebuffer dimensions (original game resolution).
pub const WIDTH = window_mod.BASE_WIDTH; // 320
pub const HEIGHT = window_mod.BASE_HEIGHT; // 200
pub const PIXEL_COUNT: usize = WIDTH * HEIGHT; // 64000

pub const Framebuffer = struct {
    /// 8-bit palette-indexed pixel buffer (320x200).
    pixels: [PIXEL_COUNT]u8,
    /// RGBA output buffer for SDL texture upload (4 bytes per pixel: R, G, B, A).
    /// Uses SDL_PIXELFORMAT_RGBA32 byte order.
    rgba: [PIXEL_COUNT * 4]u8,
    /// SDL streaming texture (null until createTexture is called).
    texture: ?*c.SDL_Texture,

    pub const Error = error{
        TextureCreateFailed,
    };

    /// Create a new framebuffer, cleared to palette index 0 (black).
    pub fn create() Framebuffer {
        var fb: Framebuffer = undefined;
        @memset(&fb.pixels, 0);
        @memset(&fb.rgba, 0);
        fb.texture = null;
        return fb;
    }

    /// Release SDL resources.
    pub fn destroy(self: *Framebuffer) void {
        if (self.texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.texture = null;
        }
    }

    /// Create the SDL streaming texture for this framebuffer.
    pub fn createTexture(self: *Framebuffer, renderer: *c.SDL_Renderer) Error!void {
        self.texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_RGBA32,
            c.SDL_TEXTUREACCESS_STREAMING,
            WIDTH,
            HEIGHT,
        ) orelse {
            std.log.err("SDL_CreateTexture failed: {s}", .{c.SDL_GetError()});
            return Error.TextureCreateFailed;
        };
        // Nearest-neighbor scaling for crisp pixel art upscaling
        _ = c.SDL_SetTextureScaleMode(self.texture.?, c.SDL_SCALEMODE_NEAREST);
    }

    /// Clear the entire framebuffer to a single palette index.
    pub fn clear(self: *Framebuffer, color_index: u8) void {
        @memset(&self.pixels, color_index);
    }

    /// Set a single pixel at (x, y) to a palette index.
    /// Out-of-bounds coordinates are silently ignored.
    pub fn setPixel(self: *Framebuffer, x: u16, y: u16, color_index: u8) void {
        if (x >= WIDTH or y >= HEIGHT) return;
        self.pixels[@as(usize, y) * WIDTH + @as(usize, x)] = color_index;
    }

    /// Get the palette index at (x, y).
    /// Returns 0 for out-of-bounds coordinates.
    pub fn getPixel(self: *const Framebuffer, x: u16, y: u16) u8 {
        if (x >= WIDTH or y >= HEIGHT) return 0;
        return self.pixels[@as(usize, y) * WIDTH + @as(usize, x)];
    }

    /// Convert the indexed framebuffer to RGBA using the given palette.
    /// Must be called before present() whenever pixels or palette change.
    pub fn applyPalette(self: *Framebuffer, palette: *const pal.Palette) void {
        for (0..PIXEL_COUNT) |i| {
            const color = palette.colors[self.pixels[i]];
            self.rgba[i * 4 + 0] = color.r;
            self.rgba[i * 4 + 1] = color.g;
            self.rgba[i * 4 + 2] = color.b;
            self.rgba[i * 4 + 3] = 255;
        }
    }

    /// Upload the RGBA buffer to the SDL texture and render it scaled to fill the window.
    /// Does nothing if no texture has been created.
    pub fn present(self: *Framebuffer, renderer: *c.SDL_Renderer) void {
        const tex = self.texture orelse return;
        _ = c.SDL_UpdateTexture(
            tex,
            null,
            &self.rgba,
            WIDTH * 4,
        );
        _ = c.SDL_RenderTexture(renderer, tex, null, null);
    }
};

// --- Tests ---

test "framebuffer dimensions match base resolution" {
    try std.testing.expectEqual(@as(usize, 320), WIDTH);
    try std.testing.expectEqual(@as(usize, 200), HEIGHT);
    try std.testing.expectEqual(@as(usize, 64000), PIXEL_COUNT);
}

test "framebuffer creates with all pixels at index 0" {
    const fb = Framebuffer.create();
    for (fb.pixels) |p| {
        try std.testing.expectEqual(@as(u8, 0), p);
    }
}

test "clear fills all pixels with given index" {
    var fb = Framebuffer.create();
    fb.clear(42);
    for (fb.pixels) |p| {
        try std.testing.expectEqual(@as(u8, 42), p);
    }
}

test "setPixel and getPixel at valid coordinates" {
    var fb = Framebuffer.create();
    fb.setPixel(160, 100, 15);
    try std.testing.expectEqual(@as(u8, 15), fb.getPixel(160, 100));
    // Other pixels remain 0
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(319, 199));
}

test "setPixel ignores out-of-bounds coordinates" {
    var fb = Framebuffer.create();
    fb.setPixel(320, 0, 1);
    fb.setPixel(0, 200, 1);
    fb.setPixel(65535, 65535, 1);
    // All pixels remain 0
    for (fb.pixels) |p| {
        try std.testing.expectEqual(@as(u8, 0), p);
    }
    // Verify via getPixel too
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(0, 0));
}

test "getPixel returns 0 for out-of-bounds coordinates" {
    var fb = Framebuffer.create();
    fb.clear(42);
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(320, 0));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(0, 200));
}

test "filling with palette index 0 produces black RGBA" {
    var fb = Framebuffer.create();
    fb.clear(0);

    // Palette with index 0 = black
    var palette: pal.Palette = undefined;
    palette.colors[0] = .{ .r = 0, .g = 0, .b = 0 };

    fb.applyPalette(&palette);

    // Every RGBA pixel should be (0, 0, 0, 255)
    for (0..PIXEL_COUNT) |i| {
        try std.testing.expectEqual(@as(u8, 0), fb.rgba[i * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 0), fb.rgba[i * 4 + 1]);
        try std.testing.expectEqual(@as(u8, 0), fb.rgba[i * 4 + 2]);
        try std.testing.expectEqual(@as(u8, 255), fb.rgba[i * 4 + 3]);
    }
}

test "applyPalette converts indexed colors to correct RGBA" {
    var fb = Framebuffer.create();
    fb.setPixel(0, 0, 1); // red
    fb.setPixel(1, 0, 2); // green
    fb.setPixel(2, 0, 3); // blue

    var palette: pal.Palette = undefined;
    palette.colors[0] = .{ .r = 0, .g = 0, .b = 0 };
    palette.colors[1] = .{ .r = 255, .g = 0, .b = 0 };
    palette.colors[2] = .{ .r = 0, .g = 255, .b = 0 };
    palette.colors[3] = .{ .r = 0, .g = 0, .b = 255 };

    fb.applyPalette(&palette);

    // Pixel (0,0) = index 1 → red
    try std.testing.expectEqual(@as(u8, 255), fb.rgba[0]);
    try std.testing.expectEqual(@as(u8, 0), fb.rgba[1]);
    try std.testing.expectEqual(@as(u8, 0), fb.rgba[2]);
    try std.testing.expectEqual(@as(u8, 255), fb.rgba[3]);

    // Pixel (1,0) = index 2 → green
    try std.testing.expectEqual(@as(u8, 0), fb.rgba[4]);
    try std.testing.expectEqual(@as(u8, 255), fb.rgba[5]);
    try std.testing.expectEqual(@as(u8, 0), fb.rgba[6]);
    try std.testing.expectEqual(@as(u8, 255), fb.rgba[7]);

    // Pixel (2,0) = index 3 → blue
    try std.testing.expectEqual(@as(u8, 0), fb.rgba[8]);
    try std.testing.expectEqual(@as(u8, 0), fb.rgba[9]);
    try std.testing.expectEqual(@as(u8, 255), fb.rgba[10]);
    try std.testing.expectEqual(@as(u8, 255), fb.rgba[11]);
}

test "drawing pixel at (160,100) with color index 15" {
    var fb = Framebuffer.create();
    fb.setPixel(160, 100, 15);

    // Verify correct buffer offset: y * 320 + x
    const expected_offset: usize = 100 * 320 + 160;
    try std.testing.expectEqual(@as(u8, 15), fb.pixels[expected_offset]);
    try std.testing.expectEqual(@as(u8, 15), fb.getPixel(160, 100));

    // Apply palette and verify RGBA
    var palette: pal.Palette = undefined;
    @memset(&palette.colors, pal.Color{ .r = 0, .g = 0, .b = 0 });
    palette.colors[15] = .{ .r = 170, .g = 170, .b = 170 };

    fb.applyPalette(&palette);

    const rgba_offset = expected_offset * 4;
    try std.testing.expectEqual(@as(u8, 170), fb.rgba[rgba_offset + 0]);
    try std.testing.expectEqual(@as(u8, 170), fb.rgba[rgba_offset + 1]);
    try std.testing.expectEqual(@as(u8, 170), fb.rgba[rgba_offset + 2]);
    try std.testing.expectEqual(@as(u8, 255), fb.rgba[rgba_offset + 3]);
}

test "SDL texture creation and present" {
    try sdl.init();
    defer sdl.shutdown();

    var win = try window_mod.Window.create(640, 400);
    defer win.destroy();

    var fb = Framebuffer.create();
    defer fb.destroy();

    try fb.createTexture(win.renderer);
    try std.testing.expect(fb.texture != null);

    // Fill with black and present (should not crash)
    fb.clear(0);
    var palette: pal.Palette = undefined;
    @memset(&palette.colors, pal.Color{ .r = 0, .g = 0, .b = 0 });
    fb.applyPalette(&palette);
    fb.present(win.renderer);
}

test "destroy cleans up texture" {
    try sdl.init();
    defer sdl.shutdown();

    var win = try window_mod.Window.create(640, 400);
    defer win.destroy();

    var fb = Framebuffer.create();
    try fb.createTexture(win.renderer);
    try std.testing.expect(fb.texture != null);

    fb.destroy();
    try std.testing.expect(fb.texture == null);
}

test "present without texture does nothing" {
    try sdl.init();
    defer sdl.shutdown();

    var win = try window_mod.Window.create(640, 400);
    defer win.destroy();

    var fb = Framebuffer.create();
    // No texture created — present should be a no-op, not crash
    fb.present(win.renderer);
}
