//! Movie text overlay system for Wing Commander: Privateer intro cinematic.
//!
//! Parses MIDTEXT.PAK as a string-list PAK (null-terminated text entries)
//! and renders text strings centered on the 320x200 framebuffer using
//! DEMOFONT.SHP. Text appears and disappears per ACTS commands during
//! movie playback.
//!
//! MIDTEXT.PAK format:
//!   Standard PAK file where each resource is a null-terminated string.
//!   Entry 0: "2669, GEMINI SECTOR, TROY SYSTEM..."
//!   Entries are referenced by sprite_index in FILD/SPRI commands when
//!   the file_ref points to the MIDTEXT.PAK FILE reference.

const std = @import("std");
const pak = @import("../formats/pak.zig");
const text_mod = @import("../render/text.zig");
const framebuffer_mod = @import("../render/framebuffer.zig");

pub const MovieTextError = error{
    /// MIDTEXT.PAK contains no text entries.
    NoTextEntries,
    /// A requested text index is out of range.
    InvalidTextIndex,
    OutOfMemory,
};

/// Screen width for centering calculations.
const SCREEN_WIDTH: u16 = 320;
/// Screen height for centering calculations.
const SCREEN_HEIGHT: u16 = 200;

/// Parsed movie text strings from MIDTEXT.PAK.
pub const MovieText = struct {
    /// Text strings indexed by resource number.
    entries: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MovieText) void {
        for (self.entries) |entry| {
            self.allocator.free(entry);
        }
        self.allocator.free(self.entries);
    }

    /// Number of text entries.
    pub fn count(self: MovieText) usize {
        return self.entries.len;
    }

    /// Get a text string by index, or null if out of range.
    pub fn getText(self: MovieText, index: usize) ?[]const u8 {
        if (index >= self.entries.len) return null;
        return self.entries[index];
    }

    /// Render a text entry centered horizontally at the given Y position.
    /// Uses the provided font and optional color override.
    /// Returns the rendered width, or 0 if the index is invalid.
    pub fn drawCentered(self: MovieText, fb: *framebuffer_mod.Framebuffer, font: *const text_mod.Font, index: usize, y: u16, color: ?u8) u16 {
        const str = self.getText(index) orelse return 0;
        const text_width = font.measureText(str);
        const x = if (text_width >= SCREEN_WIDTH) 0 else (SCREEN_WIDTH - text_width) / 2;
        return font.drawTextColored(fb, x, y, str, color);
    }
};

/// Parse MIDTEXT.PAK data into a MovieText structure.
/// The PAK contains null-terminated string resources.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) MovieTextError!MovieText {
    var pak_file = pak.parse(allocator, data) catch return MovieTextError.OutOfMemory;
    defer pak_file.deinit();

    const resource_count = pak_file.resourceCount();
    if (resource_count == 0) return MovieTextError.NoTextEntries;

    var entries: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }

    for (0..resource_count) |i| {
        const resource = pak_file.getResource(i) catch continue;
        const str = extractNullTermString(resource);
        if (str.len > 0) {
            entries.append(allocator, allocator.dupe(u8, str) catch return MovieTextError.OutOfMemory) catch return MovieTextError.OutOfMemory;
        }
    }

    if (entries.items.len == 0) return MovieTextError.NoTextEntries;

    return .{
        .entries = entries.toOwnedSlice(allocator) catch return MovieTextError.OutOfMemory,
        .allocator = allocator,
    };
}

/// Extract a null-terminated string from raw bytes.
/// Returns the slice up to (but not including) the first null byte,
/// or the entire slice if no null byte is found.
fn extractNullTermString(data: []const u8) []const u8 {
    for (data, 0..) |byte, i| {
        if (byte == 0) return data[0..i];
    }
    return data;
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "parse extracts text strings from MIDTEXT.PAK fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midtext.bin");
    defer allocator.free(data);

    var mt = try parse(allocator, data);
    defer mt.deinit();

    try std.testing.expectEqual(@as(usize, 3), mt.count());
    try std.testing.expectEqualStrings("2669, GEMINI SECTOR, TROY SYSTEM...", mt.getText(0).?);
    try std.testing.expectEqualStrings("THE STORY SO FAR...", mt.getText(1).?);
    try std.testing.expectEqualStrings("YOU ARE A PRIVATEER.", mt.getText(2).?);
}

test "getText returns null for out-of-range index" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midtext.bin");
    defer allocator.free(data);

    var mt = try parse(allocator, data);
    defer mt.deinit();

    try std.testing.expect(mt.getText(99) == null);
}

test "parse rejects empty data" {
    const allocator = std.testing.allocator;
    // Empty data should fail PAK parse → OutOfMemory (mapped from PAK error)
    const result = parse(allocator, "");
    try std.testing.expectError(MovieTextError.OutOfMemory, result);
}

test "drawCentered renders text at correct horizontal center" {
    const allocator = std.testing.allocator;

    // Load font fixture
    const font_data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(font_data);
    var font = try text_mod.Font.load(allocator, font_data, 'A');
    defer font.deinit();

    // Load midtext fixture
    const midtext_data = try testing_helpers.loadFixture(allocator, "test_midtext.bin");
    defer allocator.free(midtext_data);
    var mt = try parse(allocator, midtext_data);
    defer mt.deinit();

    var fb = framebuffer_mod.Framebuffer.create();

    // drawCentered with invalid index returns 0
    try std.testing.expectEqual(@as(u16, 0), mt.drawCentered(&fb, &font, 99, 100, null));

    // drawCentered with valid index returns non-zero width
    const width = mt.drawCentered(&fb, &font, 0, 100, 15);
    try std.testing.expect(width > 0);
}

test "drawCentered places text horizontally centered on 320px screen" {
    const allocator = std.testing.allocator;

    // Load font fixture (glyphs A=3px, B=2px, C=4px wide, spacing=1)
    const font_data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(font_data);
    var font = try text_mod.Font.load(allocator, font_data, 'A');
    defer font.deinit();

    // Build a tiny PAK with a short known string "ABC"
    // "ABC" = 3+1+2+1+4 = 11 pixels wide → centered at x = (320-11)/2 = 154
    const text_width = font.measureText("ABC");
    const expected_x = (SCREEN_WIDTH - text_width) / 2;

    // Create a minimal PAK with "ABC\0" as the single resource
    const pak_bytes = makeTestPak(&[_][]const u8{"ABC"});

    var mt = try parse(allocator, &pak_bytes);
    defer mt.deinit();

    var fb = framebuffer_mod.Framebuffer.create();
    _ = mt.drawCentered(&fb, &font, 0, 50, null);

    // Glyph 'A' row 1 (middle row): all pixels set at x, x+1, x+2
    // The 'A' glyph has pattern row 1 = ###
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(expected_x, 51));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(expected_x + 1, 51));
    try std.testing.expectEqual(@as(u8, 1), fb.getPixel(expected_x + 2, 51));
}

/// Build a minimal PAK file in a static buffer for testing.
/// Each string becomes a null-terminated resource.
fn makeTestPak(strings: []const []const u8) [256]u8 {
    var buf: [256]u8 = [_]u8{0} ** 256;
    const header_size: u32 = 4 + @as(u32, @intCast(strings.len)) * 4 + 4;
    var total: u32 = header_size;
    for (strings) |s| {
        total += @as(u32, @intCast(s.len)) + 1; // string + null terminator
    }

    // File size (LE)
    std.mem.writeInt(u32, buf[0..4], total, .little);

    // Offset table entries (3-byte offset + 0xE0 marker)
    var off = header_size;
    for (strings, 0..) |s, i| {
        const entry_offset = 4 + @as(u32, @intCast(i)) * 4;
        buf[entry_offset] = @intCast(off & 0xFF);
        buf[entry_offset + 1] = @intCast((off >> 8) & 0xFF);
        buf[entry_offset + 2] = @intCast((off >> 16) & 0xFF);
        buf[entry_offset + 3] = 0xE0;
        off += @as(u32, @intCast(s.len)) + 1;
    }

    // Terminator
    const term_offset = 4 + @as(usize, strings.len) * 4;
    buf[term_offset] = 0;
    buf[term_offset + 1] = 0;
    buf[term_offset + 2] = 0;
    buf[term_offset + 3] = 0;

    // Resource data
    var data_pos: usize = header_size;
    for (strings) |s| {
        @memcpy(buf[data_pos .. data_pos + s.len], s);
        buf[data_pos + s.len] = 0; // null terminator
        data_pos += s.len + 1;
    }

    return buf;
}
