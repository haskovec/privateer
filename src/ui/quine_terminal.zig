//! Quine 4000 computer terminal UI for Wing Commander: Privateer.
//! Renders the new-game registration screen where the player enters
//! their name and callsign. Uses the pre-rendered CUBICLE.PAK resource 8
//! background (with OPTPALS palette 28) and overlays text on the green screen.

const std = @import("std");
const framebuffer_mod = @import("../render/framebuffer.zig");
const text_mod = @import("../render/text.zig");
const sprite_mod = @import("../formats/sprite.zig");

/// TRE path for the Quine 4000 sprite data.
pub const CUBICLE_PAK = "CUBICLE.PAK";

/// OPTPALS.PAK palette index for the Quine 4000 terminal.
pub const CUBICLE_PALETTE_IDX: usize = 28;

/// CUBICLE.PAK flat resource index for the Quine 4000 device background.
/// Resource 9 is the fully composed device (screen + buttons + frame).
/// Resource 8 is just the cockpit viewscreen frame.
pub const CUBICLE_BG_RESOURCE: usize = 9;

/// Color palette indices for text overlaid on the Quine screen.
/// These indices are relative to OPTPALS palette 28.
const COLOR = struct {
    const background: u8 = 0; // black (fallback when no sprite)
    const screen_bg: u8 = 125; // teal green screen background (RGB 128,184,176)
    const prompt: u8 = 5; // dark teal text on green screen (RGB 16,60,52)
    const input: u8 = 12; // dark green-gray input text (RGB 32,48,44)
    const cursor: u8 = 12; // same as input
    const label: u8 = 61; // brown/muted label (RGB 84,52,32)
};

/// Layout constants for the Quine 4000 green screen area.
/// Coordinates are relative to the 320x200 framebuffer.
const LAYOUT = struct {
    // Green screen clear area (paint over baked-in encyclopedia text)
    const clear_x: u16 = 7;
    const clear_y: u16 = 7;
    const clear_w: u16 = 146;
    const clear_h: u16 = 162;

    // Text positions within the green screen
    const title_x: u16 = 10;
    const title_y: u16 = 12;
    const prompt_x: u16 = 10;
    const prompt_y: u16 = 50;
    const input_x: u16 = 10;
    const input_y: u16 = 66;
    const callsign_label_y: u16 = 90;
    const callsign_input_y: u16 = 106;
    const status_y: u16 = 130;
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
    /// bg_sprite: optional pre-rendered CUBICLE.PAK background (resource 9).
    /// font: optional font for text rendering (null in unit tests).
    pub fn render(self: *QuineTerminal, fb: *framebuffer_mod.Framebuffer, bg_sprite: ?sprite_mod.Sprite, font: ?*const text_mod.Font) void {
        self.cursor_counter +%= 1;

        // Render Quine 4000 device background
        if (bg_sprite) |bg| {
            fb.blitSpriteOpaque(bg, 0, 0);
            // Clear the green screen text area (paint over baked-in encyclopedia text)
            fillRect(fb, LAYOUT.clear_x, LAYOUT.clear_y, LAYOUT.clear_w, LAYOUT.clear_h, COLOR.screen_bg);
        } else {
            fb.clear(COLOR.background);
        }

        // Draw registration text on the green screen
        if (font) |f| {
            _ = f.drawTextColored(fb, LAYOUT.title_x, LAYOUT.title_y, "Please register your", COLOR.prompt);
            _ = f.drawTextColored(fb, LAYOUT.title_x, LAYOUT.title_y + 12, "new Quine 4000", COLOR.prompt);

            switch (self.phase) {
                .enter_name => {
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.prompt_y, "Enter Name!", COLOR.prompt);
                    _ = f.drawTextColored(fb, LAYOUT.input_x, LAYOUT.input_y, self.getName(), COLOR.input);
                    if (self.cursor_counter / 30 % 2 == 0) {
                        const cx = LAYOUT.input_x + @as(u16, @intCast(self.name_len)) * 8;
                        _ = f.drawTextColored(fb, cx, LAYOUT.input_y, "_", COLOR.cursor);
                    }
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.callsign_label_y, "Enter Callsign!", COLOR.label);
                },
                .enter_callsign => {
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.prompt_y, "Enter Name!", COLOR.label);
                    _ = f.drawTextColored(fb, LAYOUT.input_x, LAYOUT.input_y, self.getName(), COLOR.input);
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.callsign_label_y, "Enter Callsign!", COLOR.prompt);
                    _ = f.drawTextColored(fb, LAYOUT.input_x, LAYOUT.callsign_input_y, self.getCallsign(), COLOR.input);
                    if (self.cursor_counter / 30 % 2 == 0) {
                        const cx = LAYOUT.input_x + @as(u16, @intCast(self.callsign_len)) * 8;
                        _ = f.drawTextColored(fb, cx, LAYOUT.callsign_input_y, "_", COLOR.cursor);
                    }
                },
                .done => {
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.prompt_y, "Enter Name!", COLOR.label);
                    _ = f.drawTextColored(fb, LAYOUT.input_x, LAYOUT.input_y, self.getName(), COLOR.input);
                    _ = f.drawTextColored(fb, LAYOUT.prompt_x, LAYOUT.callsign_label_y, "Enter Callsign!", COLOR.label);
                    _ = f.drawTextColored(fb, LAYOUT.input_x, LAYOUT.callsign_input_y, self.getCallsign(), COLOR.input);
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

/// Fill a solid rectangle on the framebuffer.
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

test "render without sprite clears to black" {
    var qt = QuineTerminal.init();
    var fb = framebuffer_mod.Framebuffer.create();

    qt.render(&fb, null, null);

    // Without a background sprite, framebuffer should be cleared to black
    try std.testing.expectEqual(COLOR.background, fb.getPixel(0, 0));
    try std.testing.expectEqual(COLOR.background, fb.getPixel(160, 100));
}
