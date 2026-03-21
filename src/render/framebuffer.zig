//! Palette-based software renderer.
//! Maintains a 320x200 8-bit indexed color framebuffer, converts to RGBA
//! via palette lookup, and uploads to an SDL3 streaming texture for display.
//!
//! The original game renders at 320x200 with 256-color palettes. This module
//! replicates that pipeline: indexed pixels → palette lookup → RGBA → SDL texture.

const std = @import("std");
const sdl = @import("../sdl.zig");
const c = sdl.raw;
const pal = @import("../formats/pal.zig");
const window_mod = @import("window.zig");
const sprite_mod = @import("../formats/sprite.zig");
const viewport_mod = @import("viewport.zig");

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

    /// Convert the indexed framebuffer to RGBA with a fade multiplier.
    /// fade=0.0 produces all-black, fade=1.0 produces full palette colors.
    /// Values above 1.0 are clamped. Used for title screen fade-in effect.
    pub fn applyPaletteWithFade(self: *Framebuffer, palette: *const pal.Palette, fade: f32) void {
        const f = @min(@max(fade, 0.0), 1.0);
        for (0..PIXEL_COUNT) |i| {
            const color = palette.colors[self.pixels[i]];
            self.rgba[i * 4 + 0] = @intFromFloat(@as(f32, @floatFromInt(color.r)) * f);
            self.rgba[i * 4 + 1] = @intFromFloat(@as(f32, @floatFromInt(color.g)) * f);
            self.rgba[i * 4 + 2] = @intFromFloat(@as(f32, @floatFromInt(color.b)) * f);
            self.rgba[i * 4 + 3] = 255;
        }
    }

    /// Blit a decoded sprite onto the framebuffer at the given center position.
    /// The position (center_x, center_y) is where the sprite's origin goes;
    /// the sprite header extents determine the offset from that point.
    /// Transparent pixels (index 0) are skipped. Out-of-bounds pixels are clipped.
    pub fn blitSprite(self: *Framebuffer, spr: sprite_mod.Sprite, center_x: i32, center_y: i32) void {
        self.blitSpriteScaled(spr, center_x, center_y, 1, 1);
    }

    /// Blit a decoded sprite with scaling (nearest-neighbor).
    /// Scale is expressed as a fraction: scale_numer / scale_denom.
    /// (1/1 = 100%, 1/2 = 50%, 2/1 = 200%)
    /// Transparent pixels (index 0) are skipped. Out-of-bounds pixels are clipped.
    pub fn blitSpriteScaled(
        self: *Framebuffer,
        spr: sprite_mod.Sprite,
        center_x: i32,
        center_y: i32,
        scale_numer: u16,
        scale_denom: u16,
    ) void {
        if (scale_numer == 0 or scale_denom == 0) return;

        const src_w: i32 = @intCast(spr.width);
        const src_h: i32 = @intCast(spr.height);
        const numer: i32 = @intCast(scale_numer);
        const denom: i32 = @intCast(scale_denom);

        // Scaled destination dimensions
        const dst_w = @divTrunc(src_w * numer, denom);
        const dst_h = @divTrunc(src_h * numer, denom);
        if (dst_w <= 0 or dst_h <= 0) return;

        // Compute top-left using scaled center offsets from the sprite header
        const scaled_x1 = @divTrunc(@as(i32, spr.header.x1) * numer, denom);
        const scaled_y1 = @divTrunc(@as(i32, spr.header.y1) * numer, denom);
        const top_x = center_x - scaled_x1;
        const top_y = center_y - scaled_y1;

        // Clip destination rect to framebuffer bounds
        const start_dx: i32 = @max(0, -top_x);
        const start_dy: i32 = @max(0, -top_y);
        const end_dx: i32 = @min(dst_w, @as(i32, WIDTH) - top_x);
        const end_dy: i32 = @min(dst_h, @as(i32, HEIGHT) - top_y);
        if (start_dx >= end_dx or start_dy >= end_dy) return;

        // Blit with nearest-neighbor sampling from source
        var dy: i32 = start_dy;
        while (dy < end_dy) : (dy += 1) {
            const src_y: usize = @intCast(@divTrunc(dy * denom, numer));
            const fb_y: usize = @intCast(top_y + dy);
            if (src_y >= spr.height) continue;

            var dx: i32 = start_dx;
            while (dx < end_dx) : (dx += 1) {
                const src_x: usize = @intCast(@divTrunc(dx * denom, numer));
                if (src_x >= spr.width) continue;

                const color = spr.pixels[src_y * @as(usize, spr.width) + src_x];
                if (color == 0) continue; // transparent

                const fb_x: usize = @intCast(top_x + dx);
                self.pixels[fb_y * WIDTH + fb_x] = color;
            }
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

    /// Upload the RGBA buffer and render using a viewport destination rect.
    /// The viewport controls where the framebuffer appears on screen,
    /// enabling proper aspect ratio correction and widescreen borders.
    /// Black borders are rendered automatically (SDL clears to black before each frame).
    pub fn presentViewport(self: *Framebuffer, renderer: *c.SDL_Renderer, vp: viewport_mod.Rect) void {
        const tex = self.texture orelse return;
        _ = c.SDL_UpdateTexture(
            tex,
            null,
            &self.rgba,
            WIDTH * 4,
        );
        var dst = c.SDL_FRect{ .x = vp.x, .y = vp.y, .w = vp.w, .h = vp.h };
        _ = c.SDL_RenderTexture(renderer, tex, null, &dst);
    }

    /// Upload the RGBA buffer and render using a viewport mode.
    /// Computes the destination rect from the window dimensions and mode,
    /// then presents with proper aspect ratio or fill behavior.
    pub fn presentWithMode(self: *Framebuffer, renderer: *c.SDL_Renderer, window_w: u32, window_h: u32, mode: viewport_mod.Mode) void {
        const vp = viewport_mod.compute(mode, window_w, window_h);
        self.presentViewport(renderer, vp);
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

// --- Sprite blitting tests (Phase 3.4) ---

test "blitSprite renders sprite at correct position" {
    var fb = Framebuffer.create();

    // 4x4 sprite with center at (2,2) from each edge
    var pixels = [_]u8{
        0, 1, 1, 0,
        1, 2, 2, 1,
        1, 2, 2, 1,
        0, 1, 1, 0,
    };
    const spr = sprite_mod.Sprite{
        .header = .{ .x2 = 2, .x1 = 2, .y1 = 2, .y2 = 2 },
        .width = 4,
        .height = 4,
        .pixels = &pixels,
        .allocator = std.testing.allocator,
    };

    // Blit at center (10, 10) → top-left at (10-2, 10-2) = (8, 8)
    fb.blitSprite(spr, 10, 10);

    // Center area should have color 2
    try std.testing.expectEqual(@as(u8, 2), fb.getPixel(10, 10));
    try std.testing.expectEqual(@as(u8, 2), fb.getPixel(9, 9));
    // Edge pixels should have color 1
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(9, 8));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(10, 8));
    // Transparent pixels (index 0) should NOT be written
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(8, 8));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(11, 8));
    // Pixels outside sprite should be untouched
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(7, 7));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(12, 12));
}

test "blitSprite skips transparent pixels preserving background" {
    var fb = Framebuffer.create();
    // Fill background with color 42
    fb.clear(42);

    var pixels = [_]u8{ 0, 5, 0, 5 };
    const spr = sprite_mod.Sprite{
        .header = .{ .x2 = 1, .x1 = 1, .y1 = 1, .y2 = 1 },
        .width = 2,
        .height = 2,
        .pixels = &pixels,
        .allocator = std.testing.allocator,
    };

    fb.blitSprite(spr, 100, 100);

    // Transparent pixels preserve background color
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(99, 99));
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(99, 100));
    // Opaque pixels are written
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(100, 99));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(100, 100));
}

test "blitSprite clips at framebuffer edges" {
    var fb = Framebuffer.create();

    var pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const spr = sprite_mod.Sprite{
        .header = .{ .x2 = 2, .x1 = 1, .y1 = 1, .y2 = 2 },
        .width = 3,
        .height = 3,
        .pixels = &pixels,
        .allocator = std.testing.allocator,
    };

    // Center at (0, 0) → top-left at (-1, -1), clips top-left corner
    fb.blitSprite(spr, 0, 0);

    // Only the bottom-right 2x2 of the sprite should be visible
    // src(1,1)=5, src(2,1)=6, src(1,2)=8, src(2,2)=9
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 6), fb.getPixel(1, 0));
    try std.testing.expectEqual(@as(u8, 8), fb.getPixel(0, 1));
    try std.testing.expectEqual(@as(u8, 9), fb.getPixel(1, 1));
}

test "blitSprite fully off-screen is no-op" {
    var fb = Framebuffer.create();

    var pixels = [_]u8{ 1, 2, 3, 4 };
    const spr = sprite_mod.Sprite{
        .header = .{ .x2 = 1, .x1 = 1, .y1 = 1, .y2 = 1 },
        .width = 2,
        .height = 2,
        .pixels = &pixels,
        .allocator = std.testing.allocator,
    };

    // Way off-screen: should not modify any framebuffer pixels
    fb.blitSprite(spr, -100, -100);
    fb.blitSprite(spr, 500, 500);

    for (fb.pixels) |p| {
        try std.testing.expectEqual(@as(u8, 0), p);
    }
}

test "blitSpriteScaled at 50% produces half-size output" {
    var fb = Framebuffer.create();

    // 4x4 sprite with 2x2 blocks of color
    var pixels = [_]u8{
        1, 1, 2, 2,
        1, 1, 2, 2,
        3, 3, 4, 4,
        3, 3, 4, 4,
    };
    const spr = sprite_mod.Sprite{
        .header = .{ .x2 = 2, .x1 = 2, .y1 = 2, .y2 = 2 },
        .width = 4,
        .height = 4,
        .pixels = &pixels,
        .allocator = std.testing.allocator,
    };

    // Scale 1/2 = 50%. Scaled dims: 2x2.
    // Scaled center offset: x1=1, y1=1.
    // Top-left: (100-1, 100-1) = (99, 99)
    fb.blitSpriteScaled(spr, 100, 100, 1, 2);

    // Nearest-neighbor samples: (0,0)→src(0,0)=1, (1,0)→src(2,0)=2,
    //                           (0,1)→src(0,2)=3, (1,1)→src(2,2)=4
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(99, 99));
    try std.testing.expectEqual(@as(u8, 2), fb.getPixel(100, 99));
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(99, 100));
    try std.testing.expectEqual(@as(u8, 4), fb.getPixel(100, 100));
    // Surrounding pixels untouched
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(98, 99));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(101, 99));
}

test "blitSpriteScaled at 200% produces double-size output" {
    var fb = Framebuffer.create();

    // 2x2 sprite
    var pixels = [_]u8{ 1, 2, 3, 4 };
    const spr = sprite_mod.Sprite{
        .header = .{ .x2 = 1, .x1 = 1, .y1 = 1, .y2 = 1 },
        .width = 2,
        .height = 2,
        .pixels = &pixels,
        .allocator = std.testing.allocator,
    };

    // Scale 2/1 = 200%. Scaled dims: 4x4.
    // Scaled center offset: x1=2, y1=2.
    // Top-left: (100-2, 100-2) = (98, 98)
    fb.blitSpriteScaled(spr, 100, 100, 2, 1);

    // Each source pixel maps to 2x2 destination block
    // src(0,0)=1 → dst(98,98), (99,98), (98,99), (99,99)
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(98, 98));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(99, 98));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(98, 99));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(99, 99));
    // src(1,0)=2 → dst(100,98), (101,98), (100,99), (101,99)
    try std.testing.expectEqual(@as(u8, 2), fb.getPixel(100, 98));
    try std.testing.expectEqual(@as(u8, 2), fb.getPixel(101, 98));
    // src(0,1)=3 → dst(98,100), (99,100)
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(98, 100));
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(99, 100));
    // src(1,1)=4 → dst(100,100), (101,100), (100,101), (101,101)
    try std.testing.expectEqual(@as(u8, 4), fb.getPixel(100, 100));
    try std.testing.expectEqual(@as(u8, 4), fb.getPixel(101, 101));
    // Outside the 4x4 area
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(97, 98));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(102, 98));
}

test "blitSpriteScaled with zero scale is no-op" {
    var fb = Framebuffer.create();

    var pixels = [_]u8{ 1, 2, 3, 4 };
    const spr = sprite_mod.Sprite{
        .header = .{ .x2 = 1, .x1 = 1, .y1 = 1, .y2 = 1 },
        .width = 2,
        .height = 2,
        .pixels = &pixels,
        .allocator = std.testing.allocator,
    };

    fb.blitSpriteScaled(spr, 100, 100, 0, 1);
    fb.blitSpriteScaled(spr, 100, 100, 1, 0);

    for (fb.pixels) |p| {
        try std.testing.expectEqual(@as(u8, 0), p);
    }
}

test "blitSpriteScaled clips correctly at edges" {
    var fb = Framebuffer.create();

    var pixels = [_]u8{ 1, 2, 3, 4 };
    const spr = sprite_mod.Sprite{
        .header = .{ .x2 = 1, .x1 = 1, .y1 = 1, .y2 = 1 },
        .width = 2,
        .height = 2,
        .pixels = &pixels,
        .allocator = std.testing.allocator,
    };

    // Scale 2x, center at (319, 199) → most of the sprite is off-screen
    // Scaled dims 4x4, top-left at (317, 197)
    fb.blitSpriteScaled(spr, 319, 199, 2, 1);

    // Top-left block of scaled sprite should be visible at (317,197)-(318,198)
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(317, 197));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(318, 197));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(317, 198));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(318, 198));
    // Right column: src(1,0)=2 at (319,197), (319,198)
    try std.testing.expectEqual(@as(u8, 2), fb.getPixel(319, 197));
    try std.testing.expectEqual(@as(u8, 2), fb.getPixel(319, 198));
    // Bottom row visible: src(0,1)=3 at (317,199), (318,199)
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(317, 199));
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(318, 199));
    // src(1,1)=4 at (319,199)
    try std.testing.expectEqual(@as(u8, 4), fb.getPixel(319, 199));
}

// --- Viewport-aware present tests (Phase 3.5) ---

test "presentViewport renders without crashing" {
    try sdl.init();
    defer sdl.shutdown();

    var win = try window_mod.Window.create(1920, 1080);
    defer win.destroy();

    var fb = Framebuffer.create();
    defer fb.destroy();
    try fb.createTexture(win.renderer);

    fb.clear(0);
    var palette: pal.Palette = undefined;
    @memset(&palette.colors, pal.Color{ .r = 0, .g = 0, .b = 0 });
    fb.applyPalette(&palette);

    // Present with a 4:3 viewport on a 16:9 window
    const vp = viewport_mod.compute(.fit_4_3, 1920, 1080);
    fb.presentViewport(win.renderer, vp);
}

test "presentWithMode renders in fill mode without crashing" {
    try sdl.init();
    defer sdl.shutdown();

    var win = try window_mod.Window.create(1280, 800);
    defer win.destroy();

    var fb = Framebuffer.create();
    defer fb.destroy();
    try fb.createTexture(win.renderer);

    fb.clear(0);
    var palette: pal.Palette = undefined;
    @memset(&palette.colors, pal.Color{ .r = 0, .g = 0, .b = 0 });
    fb.applyPalette(&palette);

    fb.presentWithMode(win.renderer, 1280, 800, .fill);
}

test "presentWithMode renders in fit_4_3 mode without crashing" {
    try sdl.init();
    defer sdl.shutdown();

    var win = try window_mod.Window.create(1920, 1080);
    defer win.destroy();

    var fb = Framebuffer.create();
    defer fb.destroy();
    try fb.createTexture(win.renderer);

    fb.clear(42);
    var palette: pal.Palette = undefined;
    @memset(&palette.colors, pal.Color{ .r = 0, .g = 0, .b = 0 });
    palette.colors[42] = .{ .r = 100, .g = 50, .b = 200 };
    fb.applyPalette(&palette);

    // fit_4_3 on 16:9 → pillarboxed at 1440x1080 centered
    fb.presentWithMode(win.renderer, 1920, 1080, .fit_4_3);
}

// --- Palette fade tests (Phase 15.3) ---

test "applyPaletteWithFade at 0.0 produces all-black RGBA" {
    var fb = Framebuffer.create();
    fb.clear(1); // fill with non-zero palette index

    var palette: pal.Palette = undefined;
    palette.colors[0] = .{ .r = 0, .g = 0, .b = 0 };
    palette.colors[1] = .{ .r = 200, .g = 100, .b = 50 };

    fb.applyPaletteWithFade(&palette, 0.0);

    // Every pixel should be black (0,0,0,255) regardless of palette color
    for (0..PIXEL_COUNT) |i| {
        try std.testing.expectEqual(@as(u8, 0), fb.rgba[i * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 0), fb.rgba[i * 4 + 1]);
        try std.testing.expectEqual(@as(u8, 0), fb.rgba[i * 4 + 2]);
        try std.testing.expectEqual(@as(u8, 255), fb.rgba[i * 4 + 3]);
    }
}

test "applyPaletteWithFade at 1.0 produces full palette colors" {
    var fb = Framebuffer.create();
    fb.setPixel(0, 0, 1);
    fb.setPixel(1, 0, 2);

    var palette: pal.Palette = undefined;
    palette.colors[0] = .{ .r = 0, .g = 0, .b = 0 };
    palette.colors[1] = .{ .r = 255, .g = 128, .b = 64 };
    palette.colors[2] = .{ .r = 100, .g = 200, .b = 50 };

    fb.applyPaletteWithFade(&palette, 1.0);

    // Pixel (0,0) = index 1 → (255, 128, 64)
    try std.testing.expectEqual(@as(u8, 255), fb.rgba[0]);
    try std.testing.expectEqual(@as(u8, 128), fb.rgba[1]);
    try std.testing.expectEqual(@as(u8, 64), fb.rgba[2]);
    try std.testing.expectEqual(@as(u8, 255), fb.rgba[3]);

    // Pixel (1,0) = index 2 → (100, 200, 50)
    try std.testing.expectEqual(@as(u8, 100), fb.rgba[4]);
    try std.testing.expectEqual(@as(u8, 200), fb.rgba[5]);
    try std.testing.expectEqual(@as(u8, 50), fb.rgba[6]);
    try std.testing.expectEqual(@as(u8, 255), fb.rgba[7]);
}

test "applyPaletteWithFade at 0.5 produces half-brightness colors" {
    var fb = Framebuffer.create();
    fb.setPixel(0, 0, 1);

    var palette: pal.Palette = undefined;
    palette.colors[0] = .{ .r = 0, .g = 0, .b = 0 };
    palette.colors[1] = .{ .r = 200, .g = 100, .b = 50 };

    fb.applyPaletteWithFade(&palette, 0.5);

    // 200 * 0.5 = 100, 100 * 0.5 = 50, 50 * 0.5 = 25
    try std.testing.expectEqual(@as(u8, 100), fb.rgba[0]);
    try std.testing.expectEqual(@as(u8, 50), fb.rgba[1]);
    try std.testing.expectEqual(@as(u8, 25), fb.rgba[2]);
    try std.testing.expectEqual(@as(u8, 255), fb.rgba[3]);
}

test "applyPaletteWithFade generates intermediate palettes between black and target" {
    var fb = Framebuffer.create();
    fb.setPixel(0, 0, 1);

    var palette: pal.Palette = undefined;
    palette.colors[0] = .{ .r = 0, .g = 0, .b = 0 };
    palette.colors[1] = .{ .r = 255, .g = 255, .b = 255 };

    // Test several fade steps produce monotonically increasing brightness
    var prev_r: u8 = 0;
    const steps = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 };
    for (steps) |fade| {
        fb.applyPaletteWithFade(&palette, fade);
        const r = fb.rgba[0];
        try std.testing.expect(r >= prev_r);
        prev_r = r;
    }
    // At full fade, should be 255
    try std.testing.expectEqual(@as(u8, 255), prev_r);
}

test "applyPaletteWithFade clamps fade above 1.0" {
    var fb = Framebuffer.create();
    fb.setPixel(0, 0, 1);

    var palette: pal.Palette = undefined;
    palette.colors[0] = .{ .r = 0, .g = 0, .b = 0 };
    palette.colors[1] = .{ .r = 200, .g = 100, .b = 50 };

    fb.applyPaletteWithFade(&palette, 1.5);

    // Should clamp to 1.0 — same as full palette
    try std.testing.expectEqual(@as(u8, 200), fb.rgba[0]);
    try std.testing.expectEqual(@as(u8, 100), fb.rgba[1]);
    try std.testing.expectEqual(@as(u8, 50), fb.rgba[2]);
}

test "presentViewport without texture is no-op" {
    try sdl.init();
    defer sdl.shutdown();

    var win = try window_mod.Window.create(640, 400);
    defer win.destroy();

    var fb = Framebuffer.create();
    const vp = viewport_mod.Rect{ .x = 0, .y = 0, .w = 640, .h = 400 };
    // Should not crash with no texture
    fb.presentViewport(win.renderer, vp);
}
