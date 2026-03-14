//! Text rendering engine for Wing Commander: Privateer.
//! Loads SHP font files and renders text strings onto the framebuffer.
//! Each SHP sprite index maps to a character: glyph_index = char - first_char.
//! Supports variable-width glyphs with configurable inter-character spacing.

const std = @import("std");
const shp_mod = @import("../formats/shp.zig");
const sprite_mod = @import("../formats/sprite.zig");
const framebuffer_mod = @import("framebuffer.zig");

pub const Font = struct {
    /// Pre-decoded glyph data. Index = character - first_char.
    /// Null entries indicate characters that failed to decode (treated as spaces).
    glyphs: []?Glyph,
    /// ASCII code of the first character in this font.
    first_char: u8,
    /// Maximum glyph height across all decoded glyphs (used for line spacing).
    line_height: u16,
    /// Pixels of horizontal spacing between characters.
    spacing: u16,
    allocator: std.mem.Allocator,

    pub const Glyph = struct {
        width: u16,
        height: u16,
        /// Row-major palette-indexed pixel data. Index 0 = transparent.
        pixels: []u8,
    };

    pub const Error = error{
        InvalidFont,
        OutOfMemory,
    };

    /// Load a font from raw SHP file data.
    /// first_char is the ASCII code of the character represented by glyph index 0
    /// (typically 32 for space in Privateer fonts).
    pub fn load(allocator: std.mem.Allocator, shp_data: []const u8, first_char: u8) Error!Font {
        var shape_file = shp_mod.parse(allocator, shp_data) catch return Error.InvalidFont;
        defer shape_file.deinit();

        const count = shape_file.spriteCount();
        if (count == 0) return Error.InvalidFont;

        const glyphs = allocator.alloc(?Glyph, count) catch return Error.OutOfMemory;
        errdefer {
            for (glyphs) |maybe_glyph| {
                if (maybe_glyph) |g| allocator.free(g.pixels);
            }
            allocator.free(glyphs);
        }

        var line_height: u16 = 0;
        for (0..count) |i| {
            if (shape_file.decodeSprite(allocator, i)) |spr| {
                glyphs[i] = Glyph{
                    .width = spr.width,
                    .height = spr.height,
                    .pixels = spr.pixels,
                };
                if (spr.height > line_height) line_height = spr.height;
                // Don't deinit sprite — we took ownership of pixels
            } else |_| {
                glyphs[i] = null;
            }
        }

        return Font{
            .glyphs = glyphs,
            .first_char = first_char,
            .line_height = line_height,
            .spacing = 1,
            .allocator = allocator,
        };
    }

    /// Release all glyph data and the glyph array.
    pub fn deinit(self: *Font) void {
        for (self.glyphs) |maybe_glyph| {
            if (maybe_glyph) |g| self.allocator.free(g.pixels);
        }
        self.allocator.free(self.glyphs);
    }

    /// Number of glyph slots in this font.
    pub fn glyphCount(self: Font) usize {
        return self.glyphs.len;
    }

    /// Get the glyph for a character, or null if unmapped/failed to decode.
    pub fn getGlyph(self: Font, char: u8) ?Glyph {
        if (char < self.first_char) return null;
        const idx = char - self.first_char;
        if (idx >= self.glyphs.len) return null;
        return self.glyphs[idx];
    }

    /// Width of the space used for missing/unmapped characters.
    fn spaceWidth(self: Font) u16 {
        // Use half the line height as a reasonable default space width.
        if (self.line_height > 1) return self.line_height / 2;
        return 4;
    }

    /// Measure the pixel width of a text string without rendering.
    pub fn measureText(self: Font, text: []const u8) u16 {
        if (text.len == 0) return 0;
        var width: u16 = 0;
        for (text, 0..) |ch, i| {
            if (self.getGlyph(ch)) |glyph| {
                width += glyph.width;
            } else {
                width += self.spaceWidth();
            }
            // Add spacing between characters (not after the last one)
            if (i + 1 < text.len) {
                width += self.spacing;
            }
        }
        return width;
    }

    /// Render a text string onto the framebuffer at position (x, y) as top-left.
    /// Uses the glyphs' original palette colors. Transparent pixels (index 0) are skipped.
    /// Returns the total pixel width of the rendered text.
    pub fn drawText(self: Font, fb: *framebuffer_mod.Framebuffer, x: u16, y: u16, text: []const u8) u16 {
        return self.drawTextColored(fb, x, y, text, null);
    }

    /// Render a text string with an optional color override.
    /// If color_override is non-null, all non-transparent glyph pixels are replaced
    /// with the specified palette index. Otherwise, original glyph colors are used.
    /// Returns the total pixel width of the rendered text.
    pub fn drawTextColored(self: Font, fb: *framebuffer_mod.Framebuffer, x: u16, y: u16, text: []const u8, color_override: ?u8) u16 {
        if (text.len == 0) return 0;
        var cursor_x: u16 = x;
        for (text, 0..) |ch, i| {
            if (self.getGlyph(ch)) |glyph| {
                blitGlyph(fb, glyph, cursor_x, y, color_override);
                cursor_x += glyph.width;
            } else {
                // Missing character — advance by space width (no pixels drawn)
                cursor_x += self.spaceWidth();
            }
            // Add spacing between characters (not after the last one)
            if (i + 1 < text.len) {
                cursor_x += self.spacing;
            }
        }
        return cursor_x - x;
    }

    /// Blit a single glyph onto the framebuffer at (x, y) as top-left.
    fn blitGlyph(fb: *framebuffer_mod.Framebuffer, glyph: Glyph, x: u16, y: u16, color_override: ?u8) void {
        for (0..glyph.height) |gy| {
            for (0..glyph.width) |gx| {
                const color = glyph.pixels[gy * @as(usize, glyph.width) + gx];
                if (color == 0) continue; // transparent
                const fx: u16 = x +| @as(u16, @intCast(gx));
                const fy: u16 = y +| @as(u16, @intCast(gy));
                fb.setPixel(fx, fy, color_override orelse color);
            }
        }
    }
};

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "Font.load parses test font with 3 glyphs" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    try std.testing.expectEqual(@as(usize, 3), font.glyphCount());
    try std.testing.expectEqual(@as(u8, 'A'), font.first_char);
    try std.testing.expectEqual(@as(u16, 3), font.line_height);
}

test "Font glyph dimensions match expected values" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    // Glyph 'A': 3x3
    const a = font.getGlyph('A').?;
    try std.testing.expectEqual(@as(u16, 3), a.width);
    try std.testing.expectEqual(@as(u16, 3), a.height);

    // Glyph 'B': 2x3
    const b = font.getGlyph('B').?;
    try std.testing.expectEqual(@as(u16, 2), b.width);
    try std.testing.expectEqual(@as(u16, 3), b.height);

    // Glyph 'C': 4x3
    const c_glyph = font.getGlyph('C').?;
    try std.testing.expectEqual(@as(u16, 4), c_glyph.width);
    try std.testing.expectEqual(@as(u16, 3), c_glyph.height);
}

test "Font glyph pixel data is correct" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    // Glyph 'A': .#. / ### / #.#
    const a = font.getGlyph('A').?;
    try testing_helpers.expectBytes(&[_]u8{ 0, 1, 0 }, a.pixels[0..3]);
    try testing_helpers.expectBytes(&[_]u8{ 1, 1, 1 }, a.pixels[3..6]);
    try testing_helpers.expectBytes(&[_]u8{ 1, 0, 1 }, a.pixels[6..9]);

    // Glyph 'B': ## / #. / ##
    const b = font.getGlyph('B').?;
    try testing_helpers.expectBytes(&[_]u8{ 1, 1 }, b.pixels[0..2]);
    try testing_helpers.expectBytes(&[_]u8{ 1, 0 }, b.pixels[2..4]);
    try testing_helpers.expectBytes(&[_]u8{ 1, 1 }, b.pixels[4..6]);
}

test "Font.getGlyph returns null for unmapped characters" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    // Characters below first_char
    try std.testing.expect(font.getGlyph('@') == null);
    try std.testing.expect(font.getGlyph(' ') == null);

    // Characters beyond glyph range (only A, B, C mapped)
    try std.testing.expect(font.getGlyph('D') == null);
    try std.testing.expect(font.getGlyph('Z') == null);

    // Valid characters
    try std.testing.expect(font.getGlyph('A') != null);
    try std.testing.expect(font.getGlyph('B') != null);
    try std.testing.expect(font.getGlyph('C') != null);
}

test "Font.measureText returns correct width" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    // Single character: just glyph width, no spacing
    try std.testing.expectEqual(@as(u16, 3), font.measureText("A"));
    try std.testing.expectEqual(@as(u16, 2), font.measureText("B"));
    try std.testing.expectEqual(@as(u16, 4), font.measureText("C"));

    // "AB" = 3 (A) + 1 (spacing) + 2 (B) = 6
    try std.testing.expectEqual(@as(u16, 6), font.measureText("AB"));

    // "ABC" = 3 + 1 + 2 + 1 + 4 = 11
    try std.testing.expectEqual(@as(u16, 11), font.measureText("ABC"));

    // Empty string
    try std.testing.expectEqual(@as(u16, 0), font.measureText(""));
}

test "Font.measureText handles unmapped characters with space width" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    // line_height = 3, space_width = 3/2 = 1
    const space_w = font.spaceWidth();
    // "A A" = 3 (A) + 1 (spacing) + space_w (unmapped ' ') + 1 (spacing) + 3 (A)
    const expected: u16 = 3 + 1 + space_w + 1 + 3;
    try std.testing.expectEqual(expected, font.measureText("A A"));
}

test "Font.drawText renders 'A' at correct framebuffer position" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    var fb = framebuffer_mod.Framebuffer.create();

    // Draw 'A' at (10, 20)
    const width = font.drawText(&fb, 10, 20, "A");
    try std.testing.expectEqual(@as(u16, 3), width);

    // Glyph 'A' pattern: .#. / ### / #.#
    // Row 0: (10,20)=0, (11,20)=1, (12,20)=0
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(10, 20));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(11, 20));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(12, 20));

    // Row 1: (10,21)=1, (11,21)=1, (12,21)=1
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(10, 21));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(11, 21));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(12, 21));

    // Row 2: (10,22)=1, (11,22)=0, (12,22)=1
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(10, 22));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(11, 22));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(12, 22));
}

test "Font.drawText renders multi-character string with correct spacing" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    var fb = framebuffer_mod.Framebuffer.create();

    // Draw "AB" at (0, 0). A=3 wide, spacing=1, B=2 wide.
    // A occupies cols 0-2, gap at col 3, B occupies cols 4-5
    const width = font.drawText(&fb, 0, 0, "AB");
    try std.testing.expectEqual(@as(u16, 6), width);

    // Verify A's middle row: (0,1)=1, (1,1)=1, (2,1)=1
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(0, 1));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(1, 1));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(2, 1));

    // Gap at col 3
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(3, 0));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(3, 1));

    // Verify B at cols 4-5: top row (4,0)=1, (5,0)=1
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(4, 0));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(5, 0));
}

test "Font.drawTextColored overrides glyph colors" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    var fb = framebuffer_mod.Framebuffer.create();

    // Draw 'B' at (0, 0) with color override 42
    _ = font.drawTextColored(&fb, 0, 0, "B", 42);

    // Glyph B top row: (0,0)=42, (1,0)=42
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(1, 0));

    // Transparent pixels remain 0
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(1, 1));
}

test "Font.drawText returns correct width for string with unmapped chars" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    var fb = framebuffer_mod.Framebuffer.create();

    // Draw "AXB" where X is unmapped (uses space width)
    const width = font.drawText(&fb, 0, 0, "AXB");
    const expected = font.measureText("AXB");
    try std.testing.expectEqual(expected, width);
}

test "Font.drawText on empty string returns 0" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    var fb = framebuffer_mod.Framebuffer.create();
    try std.testing.expectEqual(@as(u16, 0), font.drawText(&fb, 0, 0, ""));
}

test "Font.drawText preserves existing framebuffer content for transparent pixels" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try Font.load(allocator, data, 'A');
    defer font.deinit();

    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(99); // fill with non-zero background

    // Draw 'A' — transparent pixels should not overwrite background
    _ = font.drawText(&fb, 10, 10, "A");

    // Glyph A row 0: .#. — transparent pixels at (10,10) and (12,10) keep background
    try std.testing.expectEqual(@as(u8, 99), fb.getPixel(10, 10));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(11, 10));
    try std.testing.expectEqual(@as(u8, 99), fb.getPixel(12, 10));
}

test "Font.load rejects empty SHP data" {
    const data = [_]u8{0} ** 8; // Too small for valid SHP
    try std.testing.expectError(Font.Error.InvalidFont, Font.load(std.testing.allocator, &data, 'A'));
}
