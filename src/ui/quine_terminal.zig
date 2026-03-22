//! Quine 4000 computer terminal UI for Wing Commander: Privateer.
//! Renders the new-game registration screen where the player enters
//! their name and callsign. Procedurally drawn to match the original
//! game's handheld PDA device appearance at 320x200 resolution.

const std = @import("std");
const framebuffer_mod = @import("../render/framebuffer.zig");
const text_mod = @import("../render/text.zig");

/// Palette indices matching PCMAIN.PAL / general game palette.
const C = struct {
    const black: u8 = 0;
    const dark_gray: u8 = 2; // dark background behind device
    const mid_gray: u8 = 4; // device casing
    const light_gray: u8 = 7; // device casing highlight
    const dark_green: u8 = 10; // green screen dark edge
    const green: u8 = 11; // green screen background
    const text: u8 = 0; // black text on green screen
    const text_dim: u8 = 4; // dimmed/inactive text
    const red: u8 = 3; // red button labels (SAVE, LOAD)
    const yellow: u8 = 11; // yellow button label (MISSIONS)
    const btn_green: u8 = 10; // green button labels (FIN, MAN)
    const white: u8 = 15; // bright highlights
    const btn_bg: u8 = 5; // button background
    const btn_border: u8 = 6; // button border
};

/// Device layout in 320x200 framebuffer coordinates.
/// The PDA is roughly centered, offset slightly down.
const D = struct {
    // Full device bounding box
    const x: u16 = 60;
    const y: u16 = 55;
    const w: u16 = 200;
    const h: u16 = 135;

    // Green screen panel (left side of device)
    const scr_x: u16 = 66;
    const scr_y: u16 = 62;
    const scr_w: u16 = 118;
    const scr_h: u16 = 118;

    // Button panel (right side of device)
    const btn_x: u16 = 190;
    const btn_y: u16 = 62;
    const btn_w: u16 = 64;
    const btn_h: u16 = 118;

    // Text on green screen
    const txt_x: u16 = 70;
    const txt_y: u16 = 68;
    const txt_line: u16 = 12;
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

    /// Render the Quine 4000 terminal procedurally.
    /// font is optional — if null, text is not rendered (for unit tests).
    pub fn render(self: *QuineTerminal, fb: *framebuffer_mod.Framebuffer, font: ?*const text_mod.Font) void {
        self.cursor_counter +%= 1;

        // Dark background (cockpit/desk surface)
        fb.clear(C.dark_gray);

        // Device casing - outer frame with 3D beveled look
        fillRect(fb, D.x, D.y, D.w, D.h, C.mid_gray);
        // Top/left highlight edge
        drawHLine(fb, D.x, D.y, D.w, C.light_gray);
        drawVLine(fb, D.x, D.y, D.h, C.light_gray);
        // Bottom/right shadow edge
        drawHLine(fb, D.x, D.y + D.h - 1, D.w, C.black);
        drawVLine(fb, D.x + D.w - 1, D.y, D.h, C.black);
        // Inner bevel
        drawHLine(fb, D.x + 1, D.y + 1, D.w - 2, C.white);
        drawVLine(fb, D.x + 1, D.y + 1, D.h - 2, C.white);
        drawHLine(fb, D.x + 1, D.y + D.h - 2, D.w - 2, C.dark_gray);
        drawVLine(fb, D.x + D.w - 2, D.y + 1, D.h - 2, C.dark_gray);

        // Green screen panel - recessed with dark border
        fillRect(fb, D.scr_x - 2, D.scr_y - 2, D.scr_w + 4, D.scr_h + 4, C.dark_green);
        fillRect(fb, D.scr_x, D.scr_y, D.scr_w, D.scr_h, C.green);

        // Button panel background
        fillRect(fb, D.btn_x, D.btn_y, D.btn_w, D.btn_h, C.mid_gray);

        // Draw buttons on right panel
        if (font) |f| {
            const bx = D.btn_x + 2;
            const bw = D.btn_w - 4;
            const half_w = bw / 2 - 1;

            // Row 1: SAVE | LOAD (side by side)
            drawButton(fb, bx, D.btn_y + 3, half_w, 14, C.btn_bg, C.btn_border);
            drawButton(fb, bx + half_w + 2, D.btn_y + 3, half_w, 14, C.btn_bg, C.btn_border);
            _ = f.drawTextColored(fb, bx + 3, D.btn_y + 7, "SAVE", C.red);
            _ = f.drawTextColored(fb, bx + half_w + 5, D.btn_y + 7, "LOAD", C.red);

            // Row 2: MISSIONS (full width)
            drawButton(fb, bx, D.btn_y + 22, bw, 14, C.btn_bg, C.btn_border);
            _ = f.drawTextColored(fb, bx + 3, D.btn_y + 26, "MISSIONS", C.yellow);

            // Row 3: FIN | MAN (side by side)
            drawButton(fb, bx, D.btn_y + 41, half_w, 14, C.btn_bg, C.btn_border);
            drawButton(fb, bx + half_w + 2, D.btn_y + 41, half_w, 14, C.btn_bg, C.btn_border);
            _ = f.drawTextColored(fb, bx + 7, D.btn_y + 45, "FIN", C.btn_green);
            _ = f.drawTextColored(fb, bx + half_w + 7, D.btn_y + 45, "MAN", C.btn_green);

            // Row 4: PWR button with d-pad
            drawButton(fb, bx + half_w + 2, D.btn_y + 60, half_w, 14, C.btn_bg, C.btn_border);
            _ = f.drawTextColored(fb, bx + half_w + 7, D.btn_y + 64, "PWR", C.red);
            // D-pad cross (simplified)
            const dx = bx + 10;
            const dy = D.btn_y + 63;
            drawHLine(fb, dx, dy + 4, 12, C.light_gray);
            drawVLine(fb, dx + 6, dy, 9, C.light_gray);

            // QUINE 4000 branding at bottom of button panel
            _ = f.drawTextColored(fb, D.btn_x + 4, D.btn_y + 82, "QUINE", C.white);
            _ = f.drawTextColored(fb, D.btn_x + 12, D.btn_y + 94, "4000", C.white);
        }

        // Green screen text content
        if (font) |f| {
            const tx = D.txt_x;
            var ty = D.txt_y;

            _ = f.drawTextColored(fb, tx, ty, "Please register your", C.text);
            ty += D.txt_line;
            _ = f.drawTextColored(fb, tx, ty, "new Quine 4000", C.text);
            ty += D.txt_line * 2;

            switch (self.phase) {
                .enter_name => {
                    _ = f.drawTextColored(fb, tx, ty, "Enter Name!", C.text);
                    ty += D.txt_line;
                    _ = f.drawTextColored(fb, tx, ty, self.getName(), C.text);
                    if (self.cursor_counter / 30 % 2 == 0) {
                        const cx = tx + @as(u16, @intCast(self.name_len)) * 8;
                        _ = f.drawTextColored(fb, cx, ty, "_", C.text);
                    }
                    ty += D.txt_line * 2;
                    _ = f.drawTextColored(fb, tx, ty, "Enter Callsign!", C.text_dim);
                },
                .enter_callsign => {
                    _ = f.drawTextColored(fb, tx, ty, "Enter Name!", C.text_dim);
                    ty += D.txt_line;
                    _ = f.drawTextColored(fb, tx, ty, self.getName(), C.text);
                    ty += D.txt_line * 2;
                    _ = f.drawTextColored(fb, tx, ty, "Enter Callsign!", C.text);
                    ty += D.txt_line;
                    _ = f.drawTextColored(fb, tx, ty, self.getCallsign(), C.text);
                    if (self.cursor_counter / 30 % 2 == 0) {
                        const cx = tx + @as(u16, @intCast(self.callsign_len)) * 8;
                        _ = f.drawTextColored(fb, cx, ty, "_", C.text);
                    }
                },
                .done => {
                    _ = f.drawTextColored(fb, tx, ty, "Enter Name!", C.text_dim);
                    ty += D.txt_line;
                    _ = f.drawTextColored(fb, tx, ty, self.getName(), C.text);
                    ty += D.txt_line * 2;
                    _ = f.drawTextColored(fb, tx, ty, "Enter Callsign!", C.text_dim);
                    ty += D.txt_line;
                    _ = f.drawTextColored(fb, tx, ty, self.getCallsign(), C.text);
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

// Drawing helpers

fn fillRect(fb: *framebuffer_mod.Framebuffer, x: u16, y: u16, w: u16, h: u16, color: u8) void {
    var j: u16 = 0;
    while (j < h) : (j += 1) {
        var i: u16 = 0;
        while (i < w) : (i += 1) {
            fb.setPixel(x + i, y + j, color);
        }
    }
}

fn drawHLine(fb: *framebuffer_mod.Framebuffer, x: u16, y: u16, w: u16, color: u8) void {
    var i: u16 = 0;
    while (i < w) : (i += 1) {
        fb.setPixel(x + i, y, color);
    }
}

fn drawVLine(fb: *framebuffer_mod.Framebuffer, x: u16, y: u16, h: u16, color: u8) void {
    var j: u16 = 0;
    while (j < h) : (j += 1) {
        fb.setPixel(x, y + j, color);
    }
}

fn drawButton(fb: *framebuffer_mod.Framebuffer, x: u16, y: u16, w: u16, h: u16, bg: u8, border: u8) void {
    fillRect(fb, x, y, w, h, bg);
    drawHLine(fb, x, y, w, border);
    drawHLine(fb, x, y + h - 1, w, border);
    drawVLine(fb, x, y, h, border);
    drawVLine(fb, x + w - 1, y, h, border);
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

test "render draws device on dark background" {
    var qt = QuineTerminal.init();
    var fb = framebuffer_mod.Framebuffer.create();
    qt.render(&fb, null);
    // Background should be dark gray
    try std.testing.expectEqual(C.dark_gray, fb.getPixel(0, 0));
    // Device casing should be mid gray (below the green screen)
    try std.testing.expectEqual(C.mid_gray, fb.getPixel(D.x + 10, D.y + D.h - 5));
    // Green screen should be green
    try std.testing.expectEqual(C.green, fb.getPixel(D.scr_x + 5, D.scr_y + 5));
}
