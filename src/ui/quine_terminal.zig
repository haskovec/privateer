//! Quine 4000 computer terminal UI for Wing Commander: Privateer.
//! Renders the new-game registration screen where the player enters
//! their name and callsign. Drawn procedurally at 320x200 resolution
//! following the options_menu.zig pattern.

const std = @import("std");
const framebuffer_mod = @import("../render/framebuffer.zig");
const text_mod = @import("../render/text.zig");

/// Color palette indices used for the Quine 4000 terminal.
const COLOR = struct {
    const background: u8 = 0; // black
    const border: u8 = 4; // gray border
    const panel_bg: u8 = 1; // dark blue panel
    const title: u8 = 11; // yellow
    const prompt: u8 = 10; // green prompt text
    const input: u8 = 15; // white input text
    const cursor: u8 = 15; // white cursor
    const label: u8 = 7; // gray labels
    const button: u8 = 4; // gray button outlines
    const button_text: u8 = 7; // gray button text
    const brand: u8 = 11; // yellow branding
};

/// Layout constants (320x200 coordinate space).
const LAYOUT = struct {
    // Outer border
    const border_x: u16 = 8;
    const border_y: u16 = 4;
    const border_w: u16 = 304;
    const border_h: u16 = 192;

    // Left panel (text display area)
    const left_x: u16 = 14;
    const left_y: u16 = 10;
    const left_w: u16 = 200;
    const left_h: u16 = 180;

    // Right panel (decorative buttons and branding)
    const right_x: u16 = 220;
    const right_y: u16 = 10;
    const right_w: u16 = 86;
    const right_h: u16 = 180;

    // Text positions within left panel
    const title_x: u16 = 20;
    const title_y: u16 = 20;
    const prompt_x: u16 = 20;
    const prompt_y: u16 = 60;
    const input_x: u16 = 20;
    const input_y: u16 = 80;
    const status_y: u16 = 120;

    // Right panel button positions
    const btn_x: u16 = 228;
    const btn_w: u16 = 70;
    const btn_h: u16 = 16;
    const brand_y: u16 = 160;
};

/// Maximum character lengths for input fields.
pub const MAX_NAME_LEN: usize = 16;
pub const MAX_CALLSIGN_LEN: usize = 12;

/// Input phase of the registration flow.
pub const Phase = enum {
    enter_name,
    enter_callsign,
    done,
};

/// Result of handling a key press.
pub const Result = enum {
    continue_input,
    cancelled,
    completed,
};

/// Quine 4000 terminal state.
pub const QuineTerminal = struct {
    phase: Phase,
    name_buf: [MAX_NAME_LEN]u8,
    name_len: usize,
    callsign_buf: [MAX_CALLSIGN_LEN]u8,
    callsign_len: usize,
    cursor_counter: u32,

    /// Create a new Quine terminal in the name entry phase.
    pub fn init() QuineTerminal {
        return .{
            .phase = .enter_name,
            .name_buf = [_]u8{0} ** MAX_NAME_LEN,
            .name_len = 0,
            .callsign_buf = [_]u8{0} ** MAX_CALLSIGN_LEN,
            .callsign_len = 0,
            .cursor_counter = 0,
        };
    }

    /// Get the entered name as a slice.
    pub fn getName(self: *const QuineTerminal) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Get the entered callsign as a slice.
    pub fn getCallsign(self: *const QuineTerminal) []const u8 {
        return self.callsign_buf[0..self.callsign_len];
    }

    /// Handle a key press. Returns the result of the input action.
    /// key: SDL keycode, key_mod: SDL modifier flags.
    pub fn handleKeyPress(self: *QuineTerminal, key: u32, key_mod: u16) Result {
        // Import SDL keycodes via the C bindings
        const c = @import("../sdl.zig").raw;

        // Escape cancels at any phase
        if (key == c.SDLK_ESCAPE) {
            return .cancelled;
        }

        switch (self.phase) {
            .enter_name => {
                if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) {
                    // Must have at least one character
                    if (self.name_len == 0) return .continue_input;
                    self.phase = .enter_callsign;
                    return .continue_input;
                }
                if (key == c.SDLK_BACKSPACE) {
                    if (self.name_len > 0) self.name_len -= 1;
                    return .continue_input;
                }
                if (charFromKey(key, key_mod)) |ch| {
                    if (self.name_len < MAX_NAME_LEN) {
                        self.name_buf[self.name_len] = ch;
                        self.name_len += 1;
                    }
                }
                return .continue_input;
            },
            .enter_callsign => {
                if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) {
                    if (self.callsign_len == 0) return .continue_input;
                    self.phase = .done;
                    return .completed;
                }
                if (key == c.SDLK_BACKSPACE) {
                    if (self.callsign_len > 0) self.callsign_len -= 1;
                    return .continue_input;
                }
                if (charFromKey(key, key_mod)) |ch| {
                    if (self.callsign_len < MAX_CALLSIGN_LEN) {
                        self.callsign_buf[self.callsign_len] = ch;
                        self.callsign_len += 1;
                    }
                }
                return .continue_input;
            },
            .done => return .completed,
        }
    }

    /// Render the terminal onto the framebuffer.
    /// font is optional — if null, text is not rendered (for unit tests).
    pub fn render(self: *QuineTerminal, fb: *framebuffer_mod.Framebuffer, font: ?*const text_mod.Font) void {
        self.cursor_counter +%= 1;

        // Clear background
        fb.clear(COLOR.background);

        // Outer border
        drawRect(fb, LAYOUT.border_x, LAYOUT.border_y, LAYOUT.border_w, LAYOUT.border_h, COLOR.border);

        // Left panel background
        fillRect(fb, LAYOUT.left_x, LAYOUT.left_y, LAYOUT.left_w, LAYOUT.left_h, COLOR.panel_bg);
        drawRect(fb, LAYOUT.left_x, LAYOUT.left_y, LAYOUT.left_w, LAYOUT.left_h, COLOR.border);

        // Right panel background
        fillRect(fb, LAYOUT.right_x, LAYOUT.right_y, LAYOUT.right_w, LAYOUT.right_h, COLOR.panel_bg);
        drawRect(fb, LAYOUT.right_x, LAYOUT.right_y, LAYOUT.right_w, LAYOUT.right_h, COLOR.border);

        // Right panel decorative buttons
        const btn_labels = [_][]const u8{ "SAVE", "LOAD", "MISSIONS", "FIN", "MAN", "PWR" };
        for (btn_labels, 0..) |lbl, i| {
            const by = LAYOUT.right_y + 6 + @as(u16, @intCast(i)) * (LAYOUT.btn_h + 4);
            drawRect(fb, LAYOUT.btn_x, by, LAYOUT.btn_w, LAYOUT.btn_h, COLOR.button);
            if (font) |f| {
                const tx = LAYOUT.btn_x + (LAYOUT.btn_w - @as(u16, @intCast(lbl.len)) * 8) / 2;
                _ = f.drawTextColored(fb, tx, by + 4, lbl, COLOR.button_text);
            }
        }

        // Branding text
        if (font) |f| {
            _ = f.drawTextColored(fb, LAYOUT.btn_x + 5, LAYOUT.brand_y, "QUINE 4000", COLOR.brand);
        }

        // Left panel content
        if (font) |f| {
            // Title
            _ = f.drawTextColored(fb, LAYOUT.title_x, LAYOUT.title_y, "QUINE 4000 REGISTRATION", COLOR.title);

            // Prompt and input based on phase
            switch (self.phase) {
                .enter_name => {
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.prompt_y, "Enter Name:", COLOR.prompt);
                    _ = f.drawTextColored(fb, LAYOUT.input_x, LAYOUT.input_y, self.getName(), COLOR.input);
                    // Blinking cursor
                    if (self.cursor_counter / 30 % 2 == 0) {
                        const cx = LAYOUT.input_x + @as(u16, @intCast(self.name_len)) * 8;
                        _ = f.drawTextColored(fb, cx, LAYOUT.input_y, "_", COLOR.cursor);
                    }
                },
                .enter_callsign => {
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.prompt_y - 16, "Name:", COLOR.label);
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x + 48, LAYOUT.prompt_y - 16, self.getName(), COLOR.input);
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.prompt_y, "Enter Callsign:", COLOR.prompt);
                    _ = f.drawTextColored(fb, LAYOUT.input_x, LAYOUT.input_y, self.getCallsign(), COLOR.input);
                    // Blinking cursor
                    if (self.cursor_counter / 30 % 2 == 0) {
                        const cx = LAYOUT.input_x + @as(u16, @intCast(self.callsign_len)) * 8;
                        _ = f.drawTextColored(fb, cx, LAYOUT.input_y, "_", COLOR.cursor);
                    }
                },
                .done => {
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.prompt_y - 16, "Name:", COLOR.label);
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x + 48, LAYOUT.prompt_y - 16, self.getName(), COLOR.input);
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.prompt_y, "Callsign:", COLOR.label);
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x + 80, LAYOUT.prompt_y, self.getCallsign(), COLOR.input);
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.status_y, "Registration complete.", COLOR.prompt);
                },
            }
        }
    }
};

/// Convert an SDL keycode + modifier to an ASCII character.
/// Returns null for non-printable keys.
fn charFromKey(key: u32, key_mod: u16) ?u8 {
    const c = @import("../sdl.zig").raw;
    const shift = (key_mod & c.SDL_KMOD_SHIFT) != 0;

    // A-Z keys
    if (key >= c.SDLK_A and key <= c.SDLK_Z) {
        const base: u8 = @intCast(key - c.SDLK_A);
        return if (shift) 'A' + base else 'a' + base;
    }
    // 0-9 keys
    if (key >= c.SDLK_0 and key <= c.SDLK_9) {
        return @intCast(key - c.SDLK_0 + '0');
    }
    // Space
    if (key == c.SDLK_SPACE) return ' ';

    return null;
}

/// Draw a hollow rectangle outline.
fn drawRect(fb: *framebuffer_mod.Framebuffer, x: u16, y: u16, w: u16, h: u16, color: u8) void {
    var i: u16 = 0;
    while (i < w) : (i += 1) {
        fb.setPixel(x + i, y, color);
        fb.setPixel(x + i, y + h - 1, color);
    }
    var j: u16 = 0;
    while (j < h) : (j += 1) {
        fb.setPixel(x, y + j, color);
        fb.setPixel(x + w - 1, y + j, color);
    }
}

/// Fill a solid rectangle.
fn fillRect(fb: *framebuffer_mod.Framebuffer, x: u16, y: u16, w: u16, h: u16, color: u8) void {
    var j: u16 = 0;
    while (j < h) : (j += 1) {
        var i: u16 = 0;
        while (i < w) : (i += 1) {
            fb.setPixel(x + i, y + j, color);
        }
    }
}

// --- Tests ---

test "QuineTerminal init starts in enter_name phase" {
    const qt = QuineTerminal.init();
    try std.testing.expectEqual(Phase.enter_name, qt.phase);
    try std.testing.expectEqual(@as(usize, 0), qt.name_len);
    try std.testing.expectEqual(@as(usize, 0), qt.callsign_len);
}

test "charFromKey returns lowercase letters without shift" {
    const c = @import("../sdl.zig").raw;
    try std.testing.expectEqual(@as(?u8, 'a'), charFromKey(c.SDLK_A, 0));
    try std.testing.expectEqual(@as(?u8, 'z'), charFromKey(c.SDLK_Z, 0));
}

test "charFromKey returns uppercase letters with shift" {
    const c = @import("../sdl.zig").raw;
    try std.testing.expectEqual(@as(?u8, 'A'), charFromKey(c.SDLK_A, c.SDL_KMOD_SHIFT));
    try std.testing.expectEqual(@as(?u8, 'Z'), charFromKey(c.SDLK_Z, c.SDL_KMOD_SHIFT));
}

test "charFromKey returns digits" {
    const c = @import("../sdl.zig").raw;
    try std.testing.expectEqual(@as(?u8, '0'), charFromKey(c.SDLK_0, 0));
    try std.testing.expectEqual(@as(?u8, '9'), charFromKey(c.SDLK_9, 0));
}

test "charFromKey returns space" {
    const c = @import("../sdl.zig").raw;
    try std.testing.expectEqual(@as(?u8, ' '), charFromKey(c.SDLK_SPACE, 0));
}

test "charFromKey returns null for non-printable" {
    const c = @import("../sdl.zig").raw;
    try std.testing.expectEqual(@as(?u8, null), charFromKey(c.SDLK_ESCAPE, 0));
    try std.testing.expectEqual(@as(?u8, null), charFromKey(c.SDLK_RETURN, 0));
}

test "handleKeyPress appends characters in name phase" {
    const c = @import("../sdl.zig").raw;
    var qt = QuineTerminal.init();
    _ = qt.handleKeyPress(c.SDLK_J, c.SDL_KMOD_SHIFT);
    _ = qt.handleKeyPress(c.SDLK_O, 0);
    _ = qt.handleKeyPress(c.SDLK_E, 0);
    try std.testing.expectEqualStrings("Joe", qt.getName());
    try std.testing.expectEqual(Phase.enter_name, qt.phase);
}

test "handleKeyPress backspace deletes in name phase" {
    const c = @import("../sdl.zig").raw;
    var qt = QuineTerminal.init();
    _ = qt.handleKeyPress(c.SDLK_A, 0);
    _ = qt.handleKeyPress(c.SDLK_B, 0);
    try std.testing.expectEqualStrings("ab", qt.getName());
    _ = qt.handleKeyPress(c.SDLK_BACKSPACE, 0);
    try std.testing.expectEqualStrings("a", qt.getName());
}

test "handleKeyPress backspace on empty name does nothing" {
    const c = @import("../sdl.zig").raw;
    var qt = QuineTerminal.init();
    const result = qt.handleKeyPress(c.SDLK_BACKSPACE, 0);
    try std.testing.expectEqual(Result.continue_input, result);
    try std.testing.expectEqual(@as(usize, 0), qt.name_len);
}

test "handleKeyPress enter with empty name stays in name phase" {
    const c = @import("../sdl.zig").raw;
    var qt = QuineTerminal.init();
    const result = qt.handleKeyPress(c.SDLK_RETURN, 0);
    try std.testing.expectEqual(Result.continue_input, result);
    try std.testing.expectEqual(Phase.enter_name, qt.phase);
}

test "handleKeyPress enter advances from name to callsign phase" {
    const c = @import("../sdl.zig").raw;
    var qt = QuineTerminal.init();
    _ = qt.handleKeyPress(c.SDLK_A, 0);
    const result = qt.handleKeyPress(c.SDLK_RETURN, 0);
    try std.testing.expectEqual(Result.continue_input, result);
    try std.testing.expectEqual(Phase.enter_callsign, qt.phase);
}

test "handleKeyPress enter with callsign completes registration" {
    const c = @import("../sdl.zig").raw;
    var qt = QuineTerminal.init();
    _ = qt.handleKeyPress(c.SDLK_A, 0);
    _ = qt.handleKeyPress(c.SDLK_RETURN, 0); // advance to callsign
    _ = qt.handleKeyPress(c.SDLK_B, 0);
    const result = qt.handleKeyPress(c.SDLK_RETURN, 0);
    try std.testing.expectEqual(Result.completed, result);
    try std.testing.expectEqual(Phase.done, qt.phase);
}

test "handleKeyPress escape cancels" {
    const c = @import("../sdl.zig").raw;
    var qt = QuineTerminal.init();
    _ = qt.handleKeyPress(c.SDLK_A, 0);
    const result = qt.handleKeyPress(c.SDLK_ESCAPE, 0);
    try std.testing.expectEqual(Result.cancelled, result);
}

test "handleKeyPress escape cancels from callsign phase" {
    const c = @import("../sdl.zig").raw;
    var qt = QuineTerminal.init();
    _ = qt.handleKeyPress(c.SDLK_A, 0);
    _ = qt.handleKeyPress(c.SDLK_RETURN, 0);
    const result = qt.handleKeyPress(c.SDLK_ESCAPE, 0);
    try std.testing.expectEqual(Result.cancelled, result);
}

test "handleKeyPress enforces max name length" {
    const c = @import("../sdl.zig").raw;
    var qt = QuineTerminal.init();
    for (0..MAX_NAME_LEN + 5) |_| {
        _ = qt.handleKeyPress(c.SDLK_A, 0);
    }
    try std.testing.expectEqual(MAX_NAME_LEN, qt.name_len);
}

test "handleKeyPress enforces max callsign length" {
    const c = @import("../sdl.zig").raw;
    var qt = QuineTerminal.init();
    _ = qt.handleKeyPress(c.SDLK_A, 0);
    _ = qt.handleKeyPress(c.SDLK_RETURN, 0);
    for (0..MAX_CALLSIGN_LEN + 5) |_| {
        _ = qt.handleKeyPress(c.SDLK_B, 0);
    }
    try std.testing.expectEqual(MAX_CALLSIGN_LEN, qt.callsign_len);
}

test "full registration flow" {
    const c = @import("../sdl.zig").raw;
    var qt = QuineTerminal.init();

    // Enter name "Ace"
    _ = qt.handleKeyPress(c.SDLK_A, c.SDL_KMOD_SHIFT);
    _ = qt.handleKeyPress(c.SDLK_C, 0);
    _ = qt.handleKeyPress(c.SDLK_E, 0);
    try std.testing.expectEqualStrings("Ace", qt.getName());

    // Confirm name
    _ = qt.handleKeyPress(c.SDLK_RETURN, 0);
    try std.testing.expectEqual(Phase.enter_callsign, qt.phase);

    // Enter callsign "Maverick"
    _ = qt.handleKeyPress(c.SDLK_M, c.SDL_KMOD_SHIFT);
    _ = qt.handleKeyPress(c.SDLK_A, 0);
    _ = qt.handleKeyPress(c.SDLK_V, 0);
    _ = qt.handleKeyPress(c.SDLK_E, 0);
    _ = qt.handleKeyPress(c.SDLK_R, 0);
    _ = qt.handleKeyPress(c.SDLK_I, 0);
    _ = qt.handleKeyPress(c.SDLK_C, 0);
    _ = qt.handleKeyPress(c.SDLK_K, 0);
    try std.testing.expectEqualStrings("Maverick", qt.getCallsign());

    // Confirm callsign
    const result = qt.handleKeyPress(c.SDLK_RETURN, 0);
    try std.testing.expectEqual(Result.completed, result);
    try std.testing.expectEqual(Phase.done, qt.phase);
}

test "render draws panels without font" {
    var qt = QuineTerminal.init();
    var fb = framebuffer_mod.Framebuffer.create();

    qt.render(&fb, null);

    // Border should be drawn
    try std.testing.expectEqual(COLOR.border, fb.getPixel(LAYOUT.border_x, LAYOUT.border_y));
    // Left panel should have panel_bg
    try std.testing.expectEqual(COLOR.panel_bg, fb.getPixel(LAYOUT.left_x + 2, LAYOUT.left_y + 2));
    // Right panel should have panel_bg
    try std.testing.expectEqual(COLOR.panel_bg, fb.getPixel(LAYOUT.right_x + 2, LAYOUT.right_y + 2));
}

test "render draws button outlines" {
    var qt = QuineTerminal.init();
    var fb = framebuffer_mod.Framebuffer.create();

    qt.render(&fb, null);

    // First button top-left corner
    const btn_y = LAYOUT.right_y + 6;
    try std.testing.expectEqual(COLOR.button, fb.getPixel(LAYOUT.btn_x, btn_y));
}
