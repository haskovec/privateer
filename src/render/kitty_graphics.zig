//! Kitty graphics protocol encoder for inline terminal image display.
//! Encodes RGBA pixel data as PNG and outputs via the Kitty graphics protocol
//! escape sequences, enabling inline image display in terminals like Ghostty and Kitty.
//!
//! Protocol: ESC_Ga=T,f=100,m=1;<base64 PNG chunk>ESC\  (chunked, max 4096 bytes per chunk)

const std = @import("std");
const png_mod = @import("png.zig");

/// Maximum base64 payload bytes per Kitty protocol chunk.
const MAX_CHUNK_SIZE: usize = 4096;

/// Errors specific to Kitty graphics output.
pub const KittyError = error{
    InvalidDimensions,
    PngEncodeFailed,
    WriteFailed,
    OutOfMemory,
};

/// Detect whether the current terminal supports the Kitty graphics protocol
/// by checking environment variables. Uses the same approach as chafa:
/// fast env-var matching against known terminals, no escape sequence probing.
///
/// Known supported terminals: Kitty, Ghostty, WezTerm, Konsole.
pub fn isKittySupported() bool {
    return isKittySupportedFromEnv(
        getenv("KITTY_PID"),
        getenv("TERM"),
        getenv("TERM_PROGRAM"),
    );
}

/// Testable core: takes env var values directly.
pub fn isKittySupportedFromEnv(
    kitty_pid: ?[]const u8,
    term: ?[]const u8,
    term_program: ?[]const u8,
) bool {
    // KITTY_PID is set by the Kitty terminal
    if (kitty_pid != null) return true;

    // Check TERM value
    if (term) |t| {
        if (std.mem.eql(u8, t, "xterm-kitty")) return true;
        if (std.mem.eql(u8, t, "xterm-ghostty")) return true;
    }

    // Check TERM_PROGRAM value
    if (term_program) |tp| {
        if (std.ascii.eqlIgnoreCase(tp, "ghostty")) return true;
        if (std.ascii.eqlIgnoreCase(tp, "wezterm")) return true;
        if (std.ascii.eqlIgnoreCase(tp, "konsole")) return true;
    }

    return false;
}

/// Read an environment variable, returning a Zig slice or null.
fn getenv(name: [*:0]const u8) ?[]const u8 {
    const c = std.c;
    const ptr = c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

/// Assumed terminal cell dimensions in pixels (typical monospace font).
const CELL_WIDTH: u32 = 8;
const CELL_HEIGHT: u32 = 16;

/// Minimum display size in terminal cells for auto-sizing.
const MIN_DISPLAY_COLS: u32 = 20;
const MIN_DISPLAY_ROWS: u32 = 10;

/// Display an RGBA image inline in the terminal using the Kitty graphics protocol.
/// Uses raw RGBA transmission (f=32) with explicit dimensions, matching the approach
/// used by chafa for maximum terminal compatibility (Ghostty, Kitty, WezTerm, Konsole).
///
/// Automatically calculates display cell size (c/r) so small images are visible.
/// Pass display_cols/display_rows as 0 to auto-calculate from pixel dimensions.
pub fn displayImage(
    writer: anytype,
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) !void {
    _ = allocator;
    // Auto-calculate display cells with a minimum size for visibility
    const cols = @max(ceilDiv(width, CELL_WIDTH), MIN_DISPLAY_COLS);
    const rows = @max(ceilDiv(height, CELL_HEIGHT), MIN_DISPLAY_ROWS);
    try displayRgba(writer, pixels, width, height, cols, rows);
}

/// Display an RGBA image with explicit display cell dimensions.
pub fn displayImageSized(
    writer: anytype,
    pixels: []const u8,
    width: u32,
    height: u32,
    display_cols: u32,
    display_rows: u32,
) !void {
    try displayRgba(writer, pixels, width, height, display_cols, display_rows);
}

fn ceilDiv(a: u32, b: u32) u32 {
    if (b == 0) return 1;
    return (a + b - 1) / b;
}

/// Display raw RGBA pixel data inline using the Kitty graphics protocol.
/// Transmits as f=32 (raw 32-bit RGBA) with chunked base64, matching chafa's
/// proven approach for broad terminal compatibility.
/// c/r specify how many terminal cells the image spans for display.
pub fn displayRgba(writer: anytype, pixels: []const u8, width: u32, height: u32, cols: u32, rows: u32) !void {
    // Hide cursor during image rendering (as chafa does)
    try writer.writeAll("\x1b[?25l");

    // Write chunks of base64-encoded raw RGBA data
    var src_offset: usize = 0;
    var first = true;

    var encode_buf: [MAX_CHUNK_SIZE]u8 = undefined;

    while (src_offset < pixels.len) {
        // 3 source bytes -> 4 base64 chars, so for MAX_CHUNK_SIZE base64 chars
        // we need at most (MAX_CHUNK_SIZE / 4) * 3 source bytes.
        const max_src_bytes = (MAX_CHUNK_SIZE / 4) * 3;
        const remaining = pixels.len - src_offset;
        const src_len = @min(remaining, max_src_bytes);
        const src_slice = pixels[src_offset .. src_offset + src_len];

        const encoded = std.base64.standard.Encoder.encode(&encode_buf, src_slice);
        const is_last = (src_offset + src_len >= pixels.len);
        const more: u8 = if (is_last) '0' else '1';

        if (first) {
            // First chunk: full parameters
            // f=32: raw 32-bit RGBA pixel data
            // s=width, v=height: pixel dimensions (required for raw format)
            // c=cols, r=rows: display size in terminal cells
            // q=2: suppress terminal responses
            try writer.print("\x1b_Ga=T,f=32,s={d},v={d},c={d},r={d},q=2,m={c};{s}\x1b\\", .{ width, height, cols, rows, more, encoded });
            first = false;
        } else {
            // Continuation chunks: only m= parameter
            try writer.print("\x1b_Gm={c};{s}\x1b\\", .{ more, encoded });
        }

        src_offset += src_len;
    }

    // Handle empty image edge case
    if (first) {
        try writer.print("\x1b_Ga=T,f=32,s={d},v={d},c={d},r={d},q=2,m=0;\x1b\\", .{ width, height, cols, rows });
    }

    // Show cursor again
    try writer.writeAll("\x1b[?25h");

    // Newline after image for proper terminal flow
    try writer.writeByte('\n');
}

/// Display a pre-encoded PNG image inline using the Kitty graphics protocol.
pub fn displayPng(writer: anytype, png_data: []const u8) !void {
    // Hide cursor during image rendering
    try writer.writeAll("\x1b[?25l");

    // Write chunks
    var src_offset: usize = 0;
    var first = true;

    var encode_buf: [MAX_CHUNK_SIZE]u8 = undefined;

    while (src_offset < png_data.len) {
        const max_src_bytes = (MAX_CHUNK_SIZE / 4) * 3;
        const remaining = png_data.len - src_offset;
        const src_len = @min(remaining, max_src_bytes);
        const src_slice = png_data[src_offset .. src_offset + src_len];

        const encoded = std.base64.standard.Encoder.encode(&encode_buf, src_slice);
        const is_last = (src_offset + src_len >= png_data.len);
        const more: u8 = if (is_last) '0' else '1';

        if (first) {
            // f=100: PNG format, q=2: suppress terminal responses
            try writer.print("\x1b_Ga=T,f=100,q=2,m={c};{s}\x1b\\", .{ more, encoded });
            first = false;
        } else {
            try writer.print("\x1b_Gm={c};{s}\x1b\\", .{ more, encoded });
        }

        src_offset += src_len;
    }

    if (first) {
        try writer.print("\x1b_Ga=T,f=100,q=2,m=0;\x1b\\", .{});
    }

    // Show cursor again
    try writer.writeAll("\x1b[?25h");

    // Newline after image for proper terminal flow
    try writer.writeByte('\n');
}

/// Composite two RGBA images side by side with a gap between them.
/// Returns a new RGBA buffer with dimensions (left_w + gap + right_w) x max(left_h, right_h).
pub fn compositeSideBySide(
    allocator: std.mem.Allocator,
    left: []const u8,
    left_w: u32,
    left_h: u32,
    right: []const u8,
    right_w: u32,
    right_h: u32,
    gap: u32,
) !CompositeResult {
    const out_w = left_w + gap + right_w;
    const out_h = @max(left_h, right_h);
    const out_pixels = try allocator.alloc(u8, @as(usize, out_w) * @as(usize, out_h) * 4);
    @memset(out_pixels, 0); // transparent background

    // Copy left image
    for (0..left_h) |y| {
        const src_row_start = y * @as(usize, left_w) * 4;
        const dst_row_start = y * @as(usize, out_w) * 4;
        @memcpy(
            out_pixels[dst_row_start .. dst_row_start + @as(usize, left_w) * 4],
            left[src_row_start .. src_row_start + @as(usize, left_w) * 4],
        );
    }

    // Copy right image
    const right_x_offset = @as(usize, left_w + gap) * 4;
    for (0..right_h) |y| {
        const src_row_start = y * @as(usize, right_w) * 4;
        const dst_row_start = y * @as(usize, out_w) * 4 + right_x_offset;
        @memcpy(
            out_pixels[dst_row_start .. dst_row_start + @as(usize, right_w) * 4],
            right[src_row_start .. src_row_start + @as(usize, right_w) * 4],
        );
    }

    return .{
        .pixels = out_pixels,
        .width = out_w,
        .height = out_h,
        .allocator = allocator,
    };
}

pub const CompositeResult = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompositeResult) void {
        self.allocator.free(self.pixels);
    }
};

// --- Tests ---

test "displayImage writes Kitty escape sequence with raw RGBA payload" {
    const allocator = std.testing.allocator;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    // 1x1 red pixel
    const pixels = [_]u8{ 255, 0, 0, 255 };
    try displayImage(output.writer(allocator), allocator, &pixels, 1, 1);

    const result = output.items;

    // Must contain cursor hide/show
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[?25l") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[?25h") != null);
    // Must contain Kitty escape with raw RGBA format and cell sizing
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b_G") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "a=T") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "f=32") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "s=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "v=1") != null);
    // Auto-sized to minimum display cells (c=20, r=10 for a 1x1 image)
    try std.testing.expect(std.mem.indexOf(u8, result, "c=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "r=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "q=2") != null);
    // Must end with newline
    try std.testing.expectEqual(@as(u8, '\n'), result[result.len - 1]);
}

test "displayImage contains valid base64 payload" {
    const allocator = std.testing.allocator;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    const pixels = [_]u8{ 0, 255, 0, 255 };
    try displayImage(output.writer(allocator), allocator, &pixels, 1, 1);

    const result = output.items;

    // Find the base64 payload between ';' and ESC (skip the cursor-hide prefix)
    if (std.mem.indexOf(u8, result, ";")) |semi_pos| {
        // Find the string terminator \x1b\ after the semicolon
        if (std.mem.indexOf(u8, result[semi_pos..], "\x1b\\")) |esc_pos| {
            const payload = result[semi_pos + 1 .. semi_pos + esc_pos];
            // Payload should be valid base64 (decodable)
            try std.testing.expect(payload.len > 0);
            // Base64 characters are alphanumeric, +, /, =
            for (payload) |c| {
                try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=');
            }
        }
    }
}

test "displayPng handles small PNG in single chunk" {
    const allocator = std.testing.allocator;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    // Encode a tiny 1x1 PNG
    const pixels = [_]u8{ 128, 128, 128, 255 };
    const png_data = try png_mod.encode(allocator, 1, 1, &pixels);
    defer allocator.free(png_data);

    try displayPng(output.writer(allocator), png_data);

    const result = output.items;

    // Must contain cursor hide/show
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[?25l") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[?25h") != null);
    // Small image should fit in single chunk (m=0 means last/only chunk)
    try std.testing.expect(std.mem.indexOf(u8, result, "m=0") != null);
    // Should NOT have m=1 (no continuation needed)
    try std.testing.expect(std.mem.indexOf(u8, result, "m=1") == null);
    // Should use PNG format
    try std.testing.expect(std.mem.indexOf(u8, result, "f=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "q=2") != null);
}

test "compositeSideBySide produces correct dimensions" {
    const allocator = std.testing.allocator;

    // 2x2 red image
    const left = [_]u8{
        255, 0, 0, 255, 255, 0, 0, 255,
        255, 0, 0, 255, 255, 0, 0, 255,
    };
    // 3x1 blue image
    const right = [_]u8{
        0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255,
    };

    var result = try compositeSideBySide(allocator, &left, 2, 2, &right, 3, 1, 4);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 9), result.width); // 2 + 4 + 3
    try std.testing.expectEqual(@as(u32, 2), result.height); // max(2, 1)
    try std.testing.expectEqual(@as(usize, 9 * 2 * 4), result.pixels.len);
}

test "isKittySupportedFromEnv detects Kitty by KITTY_PID" {
    try std.testing.expect(isKittySupportedFromEnv("12345", null, null));
}

test "isKittySupportedFromEnv detects Kitty by TERM" {
    try std.testing.expect(isKittySupportedFromEnv(null, "xterm-kitty", null));
}

test "isKittySupportedFromEnv detects Ghostty by TERM" {
    try std.testing.expect(isKittySupportedFromEnv(null, "xterm-ghostty", null));
}

test "isKittySupportedFromEnv detects Ghostty by TERM_PROGRAM" {
    try std.testing.expect(isKittySupportedFromEnv(null, null, "ghostty"));
}

test "isKittySupportedFromEnv detects WezTerm" {
    try std.testing.expect(isKittySupportedFromEnv(null, null, "WezTerm"));
}

test "isKittySupportedFromEnv detects Konsole" {
    try std.testing.expect(isKittySupportedFromEnv(null, null, "konsole"));
}

test "isKittySupportedFromEnv returns false for unsupported terminal" {
    try std.testing.expect(!isKittySupportedFromEnv(null, "xterm-256color", "Apple_Terminal"));
}

test "isKittySupportedFromEnv returns false for no env vars" {
    try std.testing.expect(!isKittySupportedFromEnv(null, null, null));
}

test "compositeSideBySide preserves left image pixels" {
    const allocator = std.testing.allocator;

    // 1x1 red
    const left = [_]u8{ 255, 0, 0, 255 };
    // 1x1 blue
    const right = [_]u8{ 0, 0, 255, 255 };

    var result = try compositeSideBySide(allocator, &left, 1, 1, &right, 1, 1, 1);
    defer result.deinit();

    // Width = 1 + 1 + 1 = 3, height = 1
    try std.testing.expectEqual(@as(u32, 3), result.width);

    // Left pixel (0,0) should be red
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, result.pixels[0..4]);
    // Gap pixel (1,0) should be transparent
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, result.pixels[4..8]);
    // Right pixel (2,0) should be blue
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, result.pixels[8..12]);
}
