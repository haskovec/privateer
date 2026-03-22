//! Quine 4000 computer terminal UI for Wing Commander: Privateer.
//! Renders the new-game registration screen where the player enters
//! their name and callsign. Uses the pre-rendered LOADSAVE.SHP sprite 0
//! (the Quine 4000 PDA device) as background with PCMAIN palette, then
//! overlays registration text on the green screen area.

const std = @import("std");
const framebuffer_mod = @import("../render/framebuffer.zig");
const text_mod = @import("../render/text.zig");
const sprite_mod = @import("../formats/sprite.zig");

/// TRE path for the Quine 4000 device sprite.
pub const LOADSAVE_SHP = "LOADSAVE.SHP";

/// Sprite index within LOADSAVE.SHP for the Quine 4000 background.
pub const QUINE_SPRITE_IDX: usize = 0;

/// Color palette indices for text on the green screen (PCMAIN palette).
const C = struct {
    const black: u8 = 0; // fallback background / text color
    const text_dim: u8 = 4; // dimmed/inactive prompt
};

/// Text layout on the green screen area of the LOADSAVE.SHP device.
/// Coordinates measured from the original 320x200 sprite.
const T = struct {
    const x: u16 = 18;
    const y: u16 = 48;
    const line: u16 = 12;
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
        const c = @import("../sdl.zig").raw;

        if (key == c.SDLK_ESCAPE) return .cancelled;

        switch (self.phase) {
            .enter_name => {
                if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) {
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

    /// Render the Quine 4000 terminal.
    /// bg: optional LOADSAVE.SHP sprite 0 (the PDA device).
    /// font: optional font for text rendering (null in unit tests).
    pub fn render(self: *QuineTerminal, fb: *framebuffer_mod.Framebuffer, bg: ?sprite_mod.Sprite, font: ?*const text_mod.Font) void {
        self.cursor_counter +%= 1;

        // Blit the pre-rendered PDA device background
        if (bg) |spr| {
            fb.blitSpriteOpaque(spr, 0, 0);
        } else {
            fb.clear(C.black);
        }

        // Overlay registration text on the green screen area
        if (font) |f| {
            const tx = T.x;
            var ty = T.y;

            _ = f.drawTextColored(fb, tx, ty, "Please register your", C.black);
            ty += T.line;
            _ = f.drawTextColored(fb, tx, ty, "new Quine 4000", C.black);
            ty += T.line * 2;

            switch (self.phase) {
                .enter_name => {
                    _ = f.drawTextColored(fb, tx, ty, "Enter Name!", C.black);
                    ty += T.line;
                    _ = f.drawTextColored(fb, tx, ty, self.getName(), C.black);
                    if (self.cursor_counter / 30 % 2 == 0) {
                        const cx = tx + @as(u16, @intCast(self.name_len)) * 8;
                        _ = f.drawTextColored(fb, cx, ty, "_", C.black);
                    }
                    ty += T.line * 2;
                    _ = f.drawTextColored(fb, tx, ty, "Enter Callsign!", C.text_dim);
                },
                .enter_callsign => {
                    _ = f.drawTextColored(fb, tx, ty, "Enter Name!", C.text_dim);
                    ty += T.line;
                    _ = f.drawTextColored(fb, tx, ty, self.getName(), C.black);
                    ty += T.line * 2;
                    _ = f.drawTextColored(fb, tx, ty, "Enter Callsign!", C.black);
                    ty += T.line;
                    _ = f.drawTextColored(fb, tx, ty, self.getCallsign(), C.black);
                    if (self.cursor_counter / 30 % 2 == 0) {
                        const cx = tx + @as(u16, @intCast(self.callsign_len)) * 8;
                        _ = f.drawTextColored(fb, cx, ty, "_", C.black);
                    }
                },
                .done => {
                    _ = f.drawTextColored(fb, tx, ty, "Enter Name!", C.text_dim);
                    ty += T.line;
                    _ = f.drawTextColored(fb, tx, ty, self.getName(), C.black);
                    ty += T.line * 2;
                    _ = f.drawTextColored(fb, tx, ty, "Enter Callsign!", C.text_dim);
                    ty += T.line;
                    _ = f.drawTextColored(fb, tx, ty, self.getCallsign(), C.black);
                },
            }
        }
    }
};

/// Convert an SDL keycode + modifier to an ASCII character.
fn charFromKey(key: u32, key_mod: u16) ?u8 {
    const c = @import("../sdl.zig").raw;
    const shift = (key_mod & c.SDL_KMOD_SHIFT) != 0;
    if (key >= c.SDLK_A and key <= c.SDLK_Z) {
        const base: u8 = @intCast(key - c.SDLK_A);
        return if (shift) 'A' + base else 'a' + base;
    }
    if (key >= c.SDLK_0 and key <= c.SDLK_9) {
        return @intCast(key - c.SDLK_0 + '0');
    }
    if (key == c.SDLK_SPACE) return ' ';
    return null;
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
    _ = qt.handleKeyPress(c.SDLK_RETURN, 0);
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
    _ = qt.handleKeyPress(c.SDLK_A, c.SDL_KMOD_SHIFT);
    _ = qt.handleKeyPress(c.SDLK_C, 0);
    _ = qt.handleKeyPress(c.SDLK_E, 0);
    try std.testing.expectEqualStrings("Ace", qt.getName());
    _ = qt.handleKeyPress(c.SDLK_RETURN, 0);
    try std.testing.expectEqual(Phase.enter_callsign, qt.phase);
    _ = qt.handleKeyPress(c.SDLK_M, c.SDL_KMOD_SHIFT);
    _ = qt.handleKeyPress(c.SDLK_A, 0);
    _ = qt.handleKeyPress(c.SDLK_V, 0);
    _ = qt.handleKeyPress(c.SDLK_E, 0);
    _ = qt.handleKeyPress(c.SDLK_R, 0);
    _ = qt.handleKeyPress(c.SDLK_I, 0);
    _ = qt.handleKeyPress(c.SDLK_C, 0);
    _ = qt.handleKeyPress(c.SDLK_K, 0);
    try std.testing.expectEqualStrings("Maverick", qt.getCallsign());
    const result = qt.handleKeyPress(c.SDLK_RETURN, 0);
    try std.testing.expectEqual(Result.completed, result);
    try std.testing.expectEqual(Phase.done, qt.phase);
}

test "render without sprite clears to black" {
    var qt = QuineTerminal.init();
    var fb = framebuffer_mod.Framebuffer.create();
    qt.render(&fb, null, null);
    // Without a background sprite, framebuffer should be cleared to black
    try std.testing.expectEqual(C.black, fb.getPixel(0, 0));
    try std.testing.expectEqual(C.black, fb.getPixel(160, 100));
}
