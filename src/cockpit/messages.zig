//! In-flight message system for Wing Commander: Privateer.
//!
//! Displays status messages, warnings, and communications in the cockpit HUD.
//! Messages are queued in a fixed-size ring buffer and rendered in the message
//! display area. Each message has a category that determines its display color
//! and a duration after which it expires.
//!
//! In the original game, messages appear in the lower-center area of the cockpit
//! viewport — things like "No Missiles", "Shields Low", "Target Locked", and
//! incoming communications from other ships.

const std = @import("std");
const mfd = @import("mfd.zig");
const framebuffer_mod = @import("../render/framebuffer.zig");
const text_mod = @import("../render/text.zig");

const Rect = mfd.Rect;

/// Maximum length of a single message string.
pub const MAX_MESSAGE_LEN = 40;

/// Maximum number of messages held in the queue.
pub const MAX_MESSAGES = 8;

/// Default message duration in seconds.
pub const DEFAULT_DURATION: f32 = 4.0;

/// Category of an in-flight message, determining display color.
pub const MessageCategory = enum {
    /// Green — general status (speed, heading, docking confirmations).
    status,
    /// Yellow — non-critical warnings (low shields, low fuel).
    warning,
    /// White — incoming communications and target info.
    incoming,
    /// Red — critical alerts (missile lock, system failures).
    critical,
};

/// Palette color indices for each message category.
pub const MessageColors = struct {
    status: u8 = 47, // green
    warning: u8 = 43, // yellow
    incoming: u8 = 15, // white
    critical: u8 = 32, // red
    background: u8 = 0, // black

    pub fn colorFor(self: MessageColors, category: MessageCategory) u8 {
        return switch (category) {
            .status => self.status,
            .warning => self.warning,
            .incoming => self.incoming,
            .critical => self.critical,
        };
    }
};

/// A single queued message.
pub const Message = struct {
    /// The message text (null-padded fixed buffer).
    text: [MAX_MESSAGE_LEN]u8 = .{0} ** MAX_MESSAGE_LEN,
    /// Actual length of the text.
    len: u8 = 0,
    /// Message category for color selection.
    category: MessageCategory = .status,
    /// Remaining display time in seconds. When <= 0 the message is expired.
    remaining: f32 = 0,
    /// Whether this slot is active (has a valid message).
    active: bool = false,

    /// Get the message text as a slice.
    pub fn textSlice(self: *const Message) []const u8 {
        return self.text[0..self.len];
    }
};

/// Ring-buffered message queue with rendering support.
pub const MessageQueue = struct {
    /// Fixed-size message buffer.
    messages: [MAX_MESSAGES]Message = .{Message{}} ** MAX_MESSAGES,
    /// Index where the next message will be written.
    write_index: u8 = 0,
    /// Display rectangle in 320x200 coordinates.
    rect: Rect,
    /// Color palette for message categories.
    colors: MessageColors = .{},

    /// Create a message queue with the given display area.
    pub fn init(rect: Rect) MessageQueue {
        return .{
            .rect = rect,
        };
    }

    /// Add a message to the queue.
    /// If the queue is full, the oldest message is overwritten.
    pub fn addMessage(self: *MessageQueue, category: MessageCategory, msg_text: []const u8) void {
        self.addMessageWithDuration(category, msg_text, DEFAULT_DURATION);
    }

    /// Add a message with a custom duration.
    pub fn addMessageWithDuration(self: *MessageQueue, category: MessageCategory, msg_text: []const u8, duration: f32) void {
        var msg = &self.messages[self.write_index];
        msg.active = true;
        msg.category = category;
        msg.remaining = duration;

        const copy_len = @min(msg_text.len, MAX_MESSAGE_LEN);
        @memcpy(msg.text[0..copy_len], msg_text[0..copy_len]);
        // Zero the rest
        if (copy_len < MAX_MESSAGE_LEN) {
            @memset(msg.text[copy_len..], 0);
        }
        msg.len = @intCast(copy_len);

        self.write_index = (self.write_index + 1) % MAX_MESSAGES;
    }

    /// Update message timers and expire old messages.
    pub fn update(self: *MessageQueue, dt: f32) void {
        for (&self.messages) |*msg| {
            if (!msg.active) continue;
            msg.remaining -= dt;
            if (msg.remaining <= 0) {
                msg.active = false;
            }
        }
    }

    /// Count the number of active (non-expired) messages.
    pub fn activeCount(self: *const MessageQueue) u8 {
        var count: u8 = 0;
        for (&self.messages) |*msg| {
            if (msg.active) count += 1;
        }
        return count;
    }

    /// Clear all messages from the queue.
    pub fn clear(self: *MessageQueue) void {
        for (&self.messages) |*msg| {
            msg.active = false;
        }
        self.write_index = 0;
    }

    /// Render active messages onto the framebuffer using the given font.
    /// Messages are drawn bottom-up (newest at the bottom of the rect).
    /// The rect is filled with the background color before drawing.
    pub fn render(self: *const MessageQueue, fb: *framebuffer_mod.Framebuffer, font: *const text_mod.Font) void {
        const h = self.rect.height();
        if (h == 0 or self.rect.width() == 0) return;

        // Fill background
        mfd.fillRect(fb, self.rect, self.colors.background);

        const line_h = font.line_height;
        if (line_h == 0) return;

        // How many lines fit in the display area?
        const max_lines: u16 = h / (line_h + 1);
        if (max_lines == 0) return;

        // Collect active messages in order (oldest first).
        // Walk backward from write_index to find the most recent messages.
        var display_msgs: [MAX_MESSAGES]*const Message = undefined;
        var display_count: u16 = 0;
        var i: u8 = 0;
        while (i < MAX_MESSAGES) : (i += 1) {
            // Walk from oldest to newest
            const idx = (self.write_index + i) % MAX_MESSAGES;
            if (self.messages[idx].active) {
                display_msgs[display_count] = &self.messages[idx];
                display_count += 1;
            }
        }

        if (display_count == 0) return;

        // Show only the most recent messages that fit.
        const show_count = @min(display_count, max_lines);
        const start = display_count - show_count;

        // Draw from top to bottom within the rect.
        var line: u16 = 0;
        while (line < show_count) : (line += 1) {
            const msg = display_msgs[start + line];
            const color = self.colors.colorFor(msg.category);
            const y = self.rect.y1 + line * (line_h + 1);
            _ = font.drawTextColored(fb, self.rect.x1, y, msg.textSlice(), color);
        }
    }

    /// Render active messages without a font, using simple single-pixel-per-char display.
    /// This is primarily useful for testing and fallback rendering.
    /// Each character is represented as a single colored pixel.
    pub fn renderSimple(self: *const MessageQueue, fb: *framebuffer_mod.Framebuffer) void {
        const h = self.rect.height();
        if (h == 0 or self.rect.width() == 0) return;

        // Fill background
        mfd.fillRect(fb, self.rect, self.colors.background);

        // Line height for simple rendering: 2 pixels (1 pixel text + 1 pixel gap)
        const line_h: u16 = 2;
        const max_lines: u16 = h / line_h;
        if (max_lines == 0) return;

        // Collect active messages oldest-first
        var display_msgs: [MAX_MESSAGES]*const Message = undefined;
        var display_count: u16 = 0;
        var i: u8 = 0;
        while (i < MAX_MESSAGES) : (i += 1) {
            const idx = (self.write_index + i) % MAX_MESSAGES;
            if (self.messages[idx].active) {
                display_msgs[display_count] = &self.messages[idx];
                display_count += 1;
            }
        }

        if (display_count == 0) return;

        const show_count = @min(display_count, max_lines);
        const start = display_count - show_count;

        var line: u16 = 0;
        while (line < show_count) : (line += 1) {
            const msg = display_msgs[start + line];
            const color = self.colors.colorFor(msg.category);
            const y = self.rect.y1 + line * line_h;
            const text_slice = msg.textSlice();
            const max_chars = @min(text_slice.len, self.rect.width());
            for (0..max_chars) |cx| {
                fb.setPixel(self.rect.x1 + @as(u16, @intCast(cx)), y, color);
            }
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

// --- Message struct ---

test "Message textSlice returns correct text" {
    var msg = Message{};
    msg.active = true;
    msg.len = 5;
    @memcpy(msg.text[0..5], "Hello");
    try testing.expectEqualStrings("Hello", msg.textSlice());
}

test "Message default state is inactive" {
    const msg = Message{};
    try testing.expect(!msg.active);
    try testing.expectEqual(@as(u8, 0), msg.len);
    try testing.expectEqual(@as(f32, 0), msg.remaining);
}

// --- MessageColors ---

test "MessageColors returns correct color per category" {
    const colors = MessageColors{};
    try testing.expectEqual(@as(u8, 47), colors.colorFor(.status));
    try testing.expectEqual(@as(u8, 43), colors.colorFor(.warning));
    try testing.expectEqual(@as(u8, 15), colors.colorFor(.incoming));
    try testing.expectEqual(@as(u8, 32), colors.colorFor(.critical));
}

// --- MessageQueue: adding messages ---

test "addMessage stores message in queue" {
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 20 });
    q.addMessage(.status, "Test message");

    try testing.expectEqual(@as(u8, 1), q.activeCount());
    try testing.expectEqualStrings("Test message", q.messages[0].textSlice());
    try testing.expectEqual(MessageCategory.status, q.messages[0].category);
    try testing.expect(q.messages[0].active);
    try testing.expectEqual(DEFAULT_DURATION, q.messages[0].remaining);
}

test "addMessage advances write index" {
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 20 });
    q.addMessage(.status, "First");
    try testing.expectEqual(@as(u8, 1), q.write_index);

    q.addMessage(.warning, "Second");
    try testing.expectEqual(@as(u8, 2), q.write_index);
}

test "addMessage wraps around when buffer is full" {
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 20 });

    // Fill all slots
    var i: u8 = 0;
    while (i < MAX_MESSAGES) : (i += 1) {
        q.addMessage(.status, "msg");
    }
    try testing.expectEqual(@as(u8, 0), q.write_index); // wrapped
    try testing.expectEqual(@as(u8, MAX_MESSAGES), q.activeCount());

    // Adding one more overwrites slot 0
    q.addMessage(.critical, "new");
    try testing.expectEqual(@as(u8, 1), q.write_index);
    try testing.expectEqualStrings("new", q.messages[0].textSlice());
    try testing.expectEqual(MessageCategory.critical, q.messages[0].category);
}

test "addMessage truncates text longer than MAX_MESSAGE_LEN" {
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 20 });
    const long_text = "A" ** (MAX_MESSAGE_LEN + 20);
    q.addMessage(.status, long_text);

    try testing.expectEqual(@as(u8, MAX_MESSAGE_LEN), q.messages[0].len);
}

test "addMessageWithDuration uses custom duration" {
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 20 });
    q.addMessageWithDuration(.warning, "Shields Low", 10.0);

    try testing.expectEqual(@as(f32, 10.0), q.messages[0].remaining);
}

// --- MessageQueue: update and expiration ---

test "update decrements remaining time" {
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 20 });
    q.addMessage(.status, "Test");

    q.update(1.0);
    try testing.expectEqual(DEFAULT_DURATION - 1.0, q.messages[0].remaining);
    try testing.expect(q.messages[0].active);
}

test "update expires message when time runs out" {
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 20 });
    q.addMessageWithDuration(.status, "Brief", 2.0);

    q.update(2.5);
    try testing.expect(!q.messages[0].active);
    try testing.expectEqual(@as(u8, 0), q.activeCount());
}

test "update does not affect inactive messages" {
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 20 });
    // Default messages are inactive
    q.update(1.0);
    try testing.expectEqual(@as(u8, 0), q.activeCount());
}

test "update expires multiple messages independently" {
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 20 });
    q.addMessageWithDuration(.status, "Short", 1.0);
    q.addMessageWithDuration(.warning, "Long", 5.0);

    q.update(2.0);
    try testing.expectEqual(@as(u8, 1), q.activeCount());
    try testing.expect(!q.messages[0].active); // Short expired
    try testing.expect(q.messages[1].active); // Long still active
}

// --- MessageQueue: clear ---

test "clear removes all messages" {
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 20 });
    q.addMessage(.status, "One");
    q.addMessage(.warning, "Two");
    q.addMessage(.critical, "Three");

    q.clear();
    try testing.expectEqual(@as(u8, 0), q.activeCount());
    try testing.expectEqual(@as(u8, 0), q.write_index);
}

// --- MessageQueue: rendering (simple mode) ---

test "renderSimple fills background in display rect" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(99);

    var q = MessageQueue.init(Rect{ .x1 = 10, .y1 = 10, .x2 = 30, .y2 = 20 });
    q.renderSimple(&fb);

    // Inside rect should be background color (0)
    try testing.expectEqual(@as(u8, 0), fb.getPixel(10, 10));
    try testing.expectEqual(@as(u8, 0), fb.getPixel(20, 15));
    // Outside rect should be untouched
    try testing.expectEqual(@as(u8, 99), fb.getPixel(9, 10));
    try testing.expectEqual(@as(u8, 99), fb.getPixel(30, 10));
}

test "renderSimple draws status message in green" {
    var fb = framebuffer_mod.Framebuffer.create();

    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 40, .y2 = 10 });
    q.addMessage(.status, "OK");
    q.renderSimple(&fb);

    // First line, first pixel should be status color (green = 47)
    try testing.expectEqual(@as(u8, 47), fb.getPixel(0, 0));
    try testing.expectEqual(@as(u8, 47), fb.getPixel(1, 0));
    // Third pixel should be background (message is 2 chars)
    try testing.expectEqual(@as(u8, 0), fb.getPixel(2, 0));
}

test "renderSimple draws warning message in yellow" {
    var fb = framebuffer_mod.Framebuffer.create();

    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 40, .y2 = 10 });
    q.addMessage(.warning, "Low");
    q.renderSimple(&fb);

    try testing.expectEqual(@as(u8, 43), fb.getPixel(0, 0));
}

test "renderSimple draws critical message in red" {
    var fb = framebuffer_mod.Framebuffer.create();

    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 40, .y2 = 10 });
    q.addMessage(.critical, "ALERT");
    q.renderSimple(&fb);

    try testing.expectEqual(@as(u8, 32), fb.getPixel(0, 0));
}

test "renderSimple draws incoming message in white" {
    var fb = framebuffer_mod.Framebuffer.create();

    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 40, .y2 = 10 });
    q.addMessage(.incoming, "Hello");
    q.renderSimple(&fb);

    try testing.expectEqual(@as(u8, 15), fb.getPixel(0, 0));
}

test "renderSimple shows newest message at bottom" {
    var fb = framebuffer_mod.Framebuffer.create();

    // Rect fits 2 lines (2px each, 4px total height)
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 40, .y2 = 4 });
    q.addMessage(.status, "Old");
    q.addMessage(.critical, "New");
    q.renderSimple(&fb);

    // Line 0 (y=0): oldest visible = "Old" (green)
    try testing.expectEqual(@as(u8, 47), fb.getPixel(0, 0));
    // Line 1 (y=2): newest = "New" (red)
    try testing.expectEqual(@as(u8, 32), fb.getPixel(0, 2));
}

test "renderSimple skips expired messages" {
    var fb = framebuffer_mod.Framebuffer.create();

    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 40, .y2 = 10 });
    q.addMessageWithDuration(.status, "Gone", 1.0);
    q.addMessage(.warning, "Here");

    q.update(1.5); // Expire the first message

    q.renderSimple(&fb);

    // Only "Here" should render (warning = yellow, line 0)
    try testing.expectEqual(@as(u8, 43), fb.getPixel(0, 0));
    // Second line should be background
    try testing.expectEqual(@as(u8, 0), fb.getPixel(0, 2));
}

test "renderSimple truncates messages wider than rect" {
    var fb = framebuffer_mod.Framebuffer.create();

    // Narrow rect: only 5 pixels wide
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 4 });
    q.addMessage(.status, "Very long message");
    q.renderSimple(&fb);

    // 5 pixels should be colored
    try testing.expectEqual(@as(u8, 47), fb.getPixel(4, 0));
    // Pixel 5 should be background
    try testing.expectEqual(@as(u8, 0), fb.getPixel(5, 0));
}

test "renderSimple drops oldest messages when too many for rect" {
    var fb = framebuffer_mod.Framebuffer.create();

    // Rect fits only 1 line (height = 2 pixels)
    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 40, .y2 = 2 });
    q.addMessage(.status, "First");
    q.addMessage(.critical, "Second");
    q.renderSimple(&fb);

    // Only the newest message ("Second", critical=red) should show
    try testing.expectEqual(@as(u8, 32), fb.getPixel(0, 0));
}

test "renderSimple handles zero-size rect gracefully" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(99);

    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0 });
    q.addMessage(.status, "Test");
    q.renderSimple(&fb);

    // Nothing should change
    try testing.expectEqual(@as(u8, 99), fb.getPixel(0, 0));
}

test "renderSimple with no active messages only fills background" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(99);

    var q = MessageQueue.init(Rect{ .x1 = 5, .y1 = 5, .x2 = 15, .y2 = 10 });
    q.renderSimple(&fb);

    // Inside should be background
    try testing.expectEqual(@as(u8, 0), fb.getPixel(5, 5));
    // Outside should be untouched
    try testing.expectEqual(@as(u8, 99), fb.getPixel(4, 5));
}

// --- "No Missiles" scenario (from implementation plan) ---

test "No Missiles message displays when firing with none" {
    var fb = framebuffer_mod.Framebuffer.create();

    var q = MessageQueue.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 40, .y2 = 10 });

    // Simulate: player tries to fire missile with none equipped
    q.addMessage(.warning, "No Missiles");

    try testing.expectEqual(@as(u8, 1), q.activeCount());
    try testing.expectEqualStrings("No Missiles", q.messages[0].textSlice());
    try testing.expectEqual(MessageCategory.warning, q.messages[0].category);

    // Render and verify it shows
    q.renderSimple(&fb);
    try testing.expectEqual(@as(u8, 43), fb.getPixel(0, 0)); // yellow for warning
}
