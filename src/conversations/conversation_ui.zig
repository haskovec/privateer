//! Conversation UI for Wing Commander: Privateer.
//! Manages conversation state and renders NPC dialogue onto the framebuffer.
//! Displays the current dialogue line with speaker name and provides
//! click-to-advance navigation through conversation scripts.
//!
//! Layout (320x200 framebuffer):
//!   - Text area at bottom of screen for dialogue
//!   - Speaker name in highlight color
//!   - Dialogue text with word wrapping
//!   - "[Continue]" prompt when more lines remain

const std = @import("std");
const conversations = @import("conversations.zig");
const framebuffer_mod = @import("../render/framebuffer.zig");
const text_mod = @import("../render/text.zig");

/// Layout constants for 320x200 framebuffer.
pub const TEXT_AREA_X: u16 = 10;
pub const TEXT_AREA_Y: u16 = 130;
pub const TEXT_AREA_WIDTH: u16 = 300;
pub const TEXT_AREA_HEIGHT: u16 = 60;
pub const TEXT_COLOR: u8 = 15; // White
pub const BG_COLOR: u8 = 0; // Black
pub const SPEAKER_COLOR: u8 = 11; // Yellow
pub const CONTINUE_COLOR: u8 = 7; // Gray
pub const LINE_PADDING: u16 = 2;

/// Result of handling a click in the conversation UI.
pub const ClickResult = enum {
    /// Click advanced to next dialogue line.
    advanced,
    /// Conversation is finished (all lines exhausted).
    finished,
    /// No action (already finished or no-op).
    none,
};

/// Conversation UI state machine.
/// Tracks the current dialogue line and provides rendering and click handling.
pub const ConversationUI = struct {
    /// Dialogue lines from the conversation script.
    lines: []const conversations.DialogueLine,
    /// Index of the currently displayed line.
    current_line: usize,

    /// Create a new ConversationUI for the given dialogue lines.
    pub fn init(lines: []const conversations.DialogueLine) ConversationUI {
        return .{
            .lines = lines,
            .current_line = 0,
        };
    }

    /// Get the currently displayed dialogue line, or null if finished.
    pub fn currentDialogue(self: *const ConversationUI) ?conversations.DialogueLine {
        if (self.current_line >= self.lines.len) return null;
        return self.lines[self.current_line];
    }

    /// Advance to the next dialogue line.
    /// Returns true if advanced successfully, false if already at end.
    pub fn advance(self: *ConversationUI) bool {
        if (self.current_line >= self.lines.len) return false;
        self.current_line += 1;
        return true;
    }

    /// Check if all dialogue lines have been exhausted.
    pub fn isFinished(self: *const ConversationUI) bool {
        return self.current_line >= self.lines.len;
    }

    /// Total number of dialogue lines in this conversation.
    pub fn lineCount(self: *const ConversationUI) usize {
        return self.lines.len;
    }

    /// Handle a click to advance the conversation.
    /// Returns .advanced if moved to next line, .finished if conversation ended.
    pub fn handleClick(self: *ConversationUI) ClickResult {
        if (self.isFinished()) return .finished;
        _ = self.advance();
        if (self.isFinished()) return .finished;
        return .advanced;
    }

    /// Render the conversation UI onto the framebuffer.
    /// Draws a text area with speaker name, dialogue text (word-wrapped),
    /// and a continue prompt if more lines remain.
    pub fn render(self: *const ConversationUI, fb: *framebuffer_mod.Framebuffer, font: *const text_mod.Font) void {
        const line = self.currentDialogue() orelse return;

        // Draw background for text area
        fillRect(fb, TEXT_AREA_X, TEXT_AREA_Y, TEXT_AREA_WIDTH, TEXT_AREA_HEIGHT, BG_COLOR);

        // Draw speaker name
        var y = TEXT_AREA_Y + LINE_PADDING;
        _ = font.drawTextColored(fb, TEXT_AREA_X + LINE_PADDING, y, line.speaker, SPEAKER_COLOR);
        y += font.line_height + LINE_PADDING;

        // Draw dialogue text with word wrapping
        const max_width = TEXT_AREA_WIDTH - LINE_PADDING * 2;
        _ = drawWrappedText(fb, font, TEXT_AREA_X + LINE_PADDING, y, max_width, line.text, TEXT_COLOR);

        // Draw continue prompt if not at last line
        if (self.current_line + 1 < self.lines.len) {
            const prompt = "[Continue]";
            const prompt_width = font.measureText(prompt);
            const prompt_x = TEXT_AREA_X + TEXT_AREA_WIDTH - prompt_width - LINE_PADDING;
            const prompt_y = TEXT_AREA_Y + TEXT_AREA_HEIGHT - font.line_height - LINE_PADDING;
            _ = font.drawTextColored(fb, prompt_x, prompt_y, prompt, CONTINUE_COLOR);
        }
    }
};

/// Measure the pixel width of a single character using the font.
fn charWidth(font: *const text_mod.Font, ch: u8) u16 {
    const single = [1]u8{ch};
    return font.measureText(&single);
}

/// Fill a rectangular area on the framebuffer with a single color.
fn fillRect(fb: *framebuffer_mod.Framebuffer, x: u16, y: u16, width: u16, height: u16, color: u8) void {
    var py: u16 = y;
    while (py < y +| height) : (py += 1) {
        var px: u16 = x;
        while (px < x +| width) : (px += 1) {
            fb.setPixel(px, py, color);
        }
    }
}

/// Draw text with word wrapping within a given max width.
/// Returns the Y position after the last line of text.
fn drawWrappedText(
    fb: *framebuffer_mod.Framebuffer,
    font: *const text_mod.Font,
    x: u16,
    start_y: u16,
    max_width: u16,
    input_text: []const u8,
    color: u8,
) u16 {
    var y = start_y;
    var remaining = input_text;

    while (remaining.len > 0) {
        const fit = findLineBreak(font, remaining, max_width);
        if (fit == 0) break;

        _ = font.drawTextColored(fb, x, y, remaining[0..fit], color);
        y += font.line_height + LINE_PADDING;
        remaining = remaining[fit..];

        // Skip leading space on next line
        if (remaining.len > 0 and remaining[0] == ' ') {
            remaining = remaining[1..];
        }
    }

    return y;
}

/// Find the position to break a line of text to fit within max_width pixels.
/// Tries to break at word boundaries (spaces).
fn findLineBreak(font: *const text_mod.Font, input_text: []const u8, max_width: u16) usize {
    if (input_text.len == 0) return 0;

    var last_space: usize = 0;
    var width: u16 = 0;

    for (input_text, 0..) |ch, i| {
        const cw = charWidth(font, ch);
        const spacing: u16 = if (i > 0) font.spacing else 0;

        if (width + spacing + cw > max_width) {
            // Line is full — break at last space if possible
            if (last_space > 0) return last_space;
            // No space found — force break at current position
            return if (i > 0) i else 1;
        }

        width += spacing + cw;

        if (ch == ' ') {
            last_space = i;
        }
    }

    // Entire text fits on one line
    return input_text.len;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

// -- State management tests --

test "ConversationUI.init starts at line 0" {
    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Hello there." },
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "How are you?" },
    };

    const ui = ConversationUI.init(&lines);
    try std.testing.expectEqual(@as(usize, 0), ui.current_line);
    try std.testing.expect(!ui.isFinished());
}

test "ConversationUI.currentDialogue returns first line" {
    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "bartender", .mood = "happy", .costume = "bar_1", .text = "Welcome!" },
    };

    const ui = ConversationUI.init(&lines);
    const dialogue = ui.currentDialogue().?;
    try std.testing.expectEqualStrings("bartender", dialogue.speaker);
    try std.testing.expectEqualStrings("Welcome!", dialogue.text);
}

test "ConversationUI.advance moves to next line" {
    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Line one." },
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Line two." },
    };

    var ui = ConversationUI.init(&lines);
    try std.testing.expect(ui.advance());
    try std.testing.expectEqual(@as(usize, 1), ui.current_line);

    const dialogue = ui.currentDialogue().?;
    try std.testing.expectEqualStrings("Line two.", dialogue.text);
}

test "ConversationUI.advance returns false at end" {
    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Only line." },
    };

    var ui = ConversationUI.init(&lines);
    try std.testing.expect(ui.advance());
    try std.testing.expect(!ui.advance());
    try std.testing.expect(ui.isFinished());
}

test "ConversationUI.isFinished is true when past last line" {
    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Hello." },
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Goodbye." },
    };

    var ui = ConversationUI.init(&lines);
    try std.testing.expect(!ui.isFinished());
    _ = ui.advance();
    try std.testing.expect(!ui.isFinished());
    _ = ui.advance();
    try std.testing.expect(ui.isFinished());
}

test "ConversationUI.currentDialogue returns null when finished" {
    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Done." },
    };

    var ui = ConversationUI.init(&lines);
    _ = ui.advance();
    try std.testing.expect(ui.currentDialogue() == null);
}

test "ConversationUI.lineCount returns total lines" {
    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "a", .mood = "m", .costume = "c", .text = "1" },
        .{ .speaker = "b", .mood = "m", .costume = "c", .text = "2" },
        .{ .speaker = "d", .mood = "m", .costume = "c", .text = "3" },
    };

    const ui = ConversationUI.init(&lines);
    try std.testing.expectEqual(@as(usize, 3), ui.lineCount());
}

test "ConversationUI with empty script is immediately finished" {
    const lines: []const conversations.DialogueLine = &.{};

    const ui = ConversationUI.init(lines);
    try std.testing.expect(ui.isFinished());
    try std.testing.expect(ui.currentDialogue() == null);
    try std.testing.expectEqual(@as(usize, 0), ui.lineCount());
}

// -- Click handling tests --

test "ConversationUI.handleClick advances and returns advanced" {
    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "First." },
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Second." },
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Third." },
    };

    var ui = ConversationUI.init(&lines);
    try std.testing.expectEqual(ClickResult.advanced, ui.handleClick());
    try std.testing.expectEqual(@as(usize, 1), ui.current_line);
}

test "ConversationUI.handleClick returns finished on last line" {
    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Only line." },
    };

    var ui = ConversationUI.init(&lines);
    try std.testing.expectEqual(ClickResult.finished, ui.handleClick());
    try std.testing.expect(ui.isFinished());
}

test "ConversationUI.handleClick returns finished when already finished" {
    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Done." },
    };

    var ui = ConversationUI.init(&lines);
    _ = ui.handleClick();
    try std.testing.expectEqual(ClickResult.finished, ui.handleClick());
}

test "ConversationUI.handleClick full walkthrough of 3-line script" {
    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "One." },
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Two." },
        .{ .speaker = "npc", .mood = "normal", .costume = "cu_1", .text = "Three." },
    };

    var ui = ConversationUI.init(&lines);
    try std.testing.expectEqual(ClickResult.advanced, ui.handleClick()); // 0→1
    try std.testing.expectEqual(ClickResult.advanced, ui.handleClick()); // 1→2
    try std.testing.expectEqual(ClickResult.finished, ui.handleClick()); // 2→done
    try std.testing.expect(ui.isFinished());
}

// -- Text wrapping tests --

test "findLineBreak fits entire short text" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try text_mod.Font.load(allocator, data, 'A');
    defer font.deinit();

    // "ABC" = 3+1+2+1+4 = 11px, max_width=100 → fits entirely
    const result = findLineBreak(&font, "ABC", 100);
    try std.testing.expectEqual(@as(usize, 3), result);
}

test "findLineBreak breaks at word boundary" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try text_mod.Font.load(allocator, data, 'A');
    defer font.deinit();

    // Font: A=3px, B=2px, C=4px, space=1px (unmapped), spacing=1
    // "AB CB": A(3) +sp(1)+B(2)=6 +sp(1)+spc(1)=8 +sp(1)+C(4)=13 > 8
    // Break at last_space=2 → "AB"
    const result = findLineBreak(&font, "AB CB", 8);
    try std.testing.expectEqual(@as(usize, 2), result);
}

test "findLineBreak handles text that exactly fits" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try text_mod.Font.load(allocator, data, 'A');
    defer font.deinit();

    // "AB" = 3+1+2 = 6 pixels, max_width=6 → fits exactly
    const result = findLineBreak(&font, "AB", 6);
    try std.testing.expectEqual(@as(usize, 2), result);
}

test "findLineBreak returns 0 for empty text" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try text_mod.Font.load(allocator, data, 'A');
    defer font.deinit();

    const result = findLineBreak(&font, "", 100);
    try std.testing.expectEqual(@as(usize, 0), result);
}

test "findLineBreak forces break when no spaces" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try text_mod.Font.load(allocator, data, 'A');
    defer font.deinit();

    // "ABCABC": A(3)+B(2+1)+C(4+1)=11 > 8, no spaces → force break at i=2
    // A(3) +sp(1)+B(2)=6 +sp(1)+C(4)=11 > 8 → break at i=2
    const result = findLineBreak(&font, "ABCABC", 8);
    try std.testing.expectEqual(@as(usize, 2), result);
}

// -- fillRect tests --

test "fillRect fills the specified area" {
    var fb = framebuffer_mod.Framebuffer.create();
    fillRect(&fb, 10, 20, 5, 3, 42);

    // Inside the rect
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(10, 20));
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(14, 22));
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(12, 21));

    // Outside the rect
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(9, 20));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(15, 20));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(10, 19));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(10, 23));
}

test "fillRect with zero dimensions draws nothing" {
    var fb = framebuffer_mod.Framebuffer.create();
    fillRect(&fb, 10, 10, 0, 0, 42);

    for (fb.pixels) |p| {
        try std.testing.expectEqual(@as(u8, 0), p);
    }
}

// -- Render tests --

test "ConversationUI.render draws speaker name on framebuffer" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try text_mod.Font.load(allocator, data, 'A');
    defer font.deinit();

    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "ABC", .mood = "normal", .costume = "cu_1", .text = "ABC" },
    };

    var fb = framebuffer_mod.Framebuffer.create();
    const ui = ConversationUI.init(&lines);
    ui.render(&fb, &font);

    // Speaker "ABC" drawn at (TEXT_AREA_X + LINE_PADDING, TEXT_AREA_Y + LINE_PADDING)
    // = (12, 132). Glyph 'A' row 1 (middle) is all solid → SPEAKER_COLOR
    const speaker_y = TEXT_AREA_Y + LINE_PADDING;
    try std.testing.expectEqual(SPEAKER_COLOR, fb.getPixel(TEXT_AREA_X + LINE_PADDING, speaker_y + 1));
}

test "ConversationUI.render draws dialogue text below speaker" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try text_mod.Font.load(allocator, data, 'A');
    defer font.deinit();

    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "A", .mood = "normal", .costume = "cu_1", .text = "B" },
    };

    var fb = framebuffer_mod.Framebuffer.create();
    const ui = ConversationUI.init(&lines);
    ui.render(&fb, &font);

    // Dialogue text "B" at y = TEXT_AREA_Y + LINE_PADDING + line_height + LINE_PADDING
    // = 132 + 3 + 2 = 137. Glyph 'B' row 0: ## → both pixels = TEXT_COLOR
    const text_y: u16 = TEXT_AREA_Y + LINE_PADDING + font.line_height + LINE_PADDING;
    try std.testing.expectEqual(TEXT_COLOR, fb.getPixel(TEXT_AREA_X + LINE_PADDING, text_y));
}

test "ConversationUI.render fills background" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try text_mod.Font.load(allocator, data, 'A');
    defer font.deinit();

    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "A", .mood = "normal", .costume = "cu_1", .text = "B" },
    };

    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(99); // fill entire screen with non-zero background
    const ui = ConversationUI.init(&lines);
    ui.render(&fb, &font);

    // Text area corners should be BG_COLOR (0), not the original fill
    try std.testing.expectEqual(BG_COLOR, fb.getPixel(TEXT_AREA_X, TEXT_AREA_Y));
    try std.testing.expectEqual(
        BG_COLOR,
        fb.getPixel(TEXT_AREA_X + TEXT_AREA_WIDTH - 1, TEXT_AREA_Y + TEXT_AREA_HEIGHT - 1),
    );

    // Outside the text area should still be the original fill
    try std.testing.expectEqual(@as(u8, 99), fb.getPixel(0, 0));
}

test "ConversationUI.render does nothing when finished" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_font.bin");
    defer allocator.free(data);

    var font = try text_mod.Font.load(allocator, data, 'A');
    defer font.deinit();

    const lines = [_]conversations.DialogueLine{
        .{ .speaker = "A", .mood = "normal", .costume = "cu_1", .text = "B" },
    };

    var ui = ConversationUI.init(&lines);
    _ = ui.advance(); // finish the conversation

    var fb = framebuffer_mod.Framebuffer.create();
    ui.render(&fb, &font);

    // Framebuffer should remain all zeros (nothing rendered)
    for (fb.pixels) |p| {
        try std.testing.expectEqual(@as(u8, 0), p);
    }
}
