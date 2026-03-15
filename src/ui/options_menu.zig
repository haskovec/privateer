//! Options menu UI for Wing Commander: Privateer.
//! Renders a settings screen at 320x200 resolution with selectable options
//! for graphics and audio settings. Handles mouse click input for navigation
//! and value changes.

const std = @import("std");
const framebuffer_mod = @import("../render/framebuffer.zig");
const settings_mod = @import("../settings.zig");
const viewport = @import("../render/viewport.zig");
const upscale_mod = @import("../render/upscale.zig");

/// Color palette indices used in the options menu.
const COLOR = struct {
    const background: u8 = 0; // black
    const border: u8 = 4; // gray border
    const title: u8 = 11; // yellow
    const label: u8 = 15; // white
    const value: u8 = 10; // highlight green
    const selected_bg: u8 = 1; // dark blue selection bar
    const button: u8 = 7; // gray button text
    const button_active: u8 = 15; // white active button
};

/// Menu items in display order.
pub const MenuItem = enum(u8) {
    scale_factor = 0,
    fullscreen = 1,
    viewport_mode = 2,
    sfx_volume = 3,
    music_volume = 4,
    accept = 5,
    cancel = 6,

    pub const COUNT: u8 = 7;
};

/// Layout constants (320x200 coordinate space).
const LAYOUT = struct {
    const title_y: u16 = 12;
    const first_item_y: u16 = 40;
    const item_height: u16 = 20;
    const label_x: u16 = 30;
    const value_x: u16 = 200;
    const left_arrow_x: u16 = 185;
    const right_arrow_x: u16 = 280;
    const button_y: u16 = 160;
    const accept_x: u16 = 80;
    const cancel_x: u16 = 190;
    const border_x: u16 = 10;
    const border_y: u16 = 5;
    const border_w: u16 = 300;
    const border_h: u16 = 190;
};

/// Result of processing a click in the options menu.
pub const ClickResult = enum {
    /// No action taken.
    none,
    /// Settings accepted, apply and close.
    accept,
    /// Settings cancelled, discard and close.
    cancel,
};

/// Options menu state.
pub const OptionsMenu = struct {
    /// The settings being edited (copy of current settings).
    editing: settings_mod.Settings,
    /// Currently selected menu item.
    selected: MenuItem,
    /// The original settings (for cancel/revert).
    original: settings_mod.Settings,

    /// Create a new options menu with the given current settings.
    pub fn init(current: settings_mod.Settings) OptionsMenu {
        return .{
            .editing = current,
            .selected = .scale_factor,
            .original = current,
        };
    }

    /// Get the Y position of a menu item.
    fn itemY(item: MenuItem) u16 {
        const idx: u16 = @intFromEnum(item);
        if (idx >= @intFromEnum(MenuItem.accept)) {
            return LAYOUT.button_y;
        }
        return LAYOUT.first_item_y + idx * LAYOUT.item_height;
    }

    /// Move selection up.
    pub fn moveUp(self: *OptionsMenu) void {
        const idx = @intFromEnum(self.selected);
        if (idx > 0) {
            self.selected = @enumFromInt(idx - 1);
        }
    }

    /// Move selection down.
    pub fn moveDown(self: *OptionsMenu) void {
        const idx = @intFromEnum(self.selected);
        if (idx + 1 < MenuItem.COUNT) {
            self.selected = @enumFromInt(idx + 1);
        }
    }

    /// Adjust the selected option's value left (decrease).
    pub fn adjustLeft(self: *OptionsMenu) void {
        switch (self.selected) {
            .scale_factor => {
                self.editing.scale_factor = switch (self.editing.scale_factor) {
                    .x4 => .x3,
                    .x3 => .x2,
                    .x2 => .x2,
                };
            },
            .fullscreen => self.editing.fullscreen = !self.editing.fullscreen,
            .viewport_mode => {
                self.editing.viewport_mode = switch (self.editing.viewport_mode) {
                    .fill => .fit_4_3,
                    .fit_4_3 => .fit_4_3,
                };
            },
            .sfx_volume => {
                self.editing.sfx_volume = @max(0.0, self.editing.sfx_volume - 0.1);
            },
            .music_volume => {
                self.editing.music_volume = @max(0.0, self.editing.music_volume - 0.1);
            },
            .accept, .cancel => {},
        }
    }

    /// Adjust the selected option's value right (increase).
    pub fn adjustRight(self: *OptionsMenu) void {
        switch (self.selected) {
            .scale_factor => {
                self.editing.scale_factor = switch (self.editing.scale_factor) {
                    .x2 => .x3,
                    .x3 => .x4,
                    .x4 => .x4,
                };
            },
            .fullscreen => self.editing.fullscreen = !self.editing.fullscreen,
            .viewport_mode => {
                self.editing.viewport_mode = switch (self.editing.viewport_mode) {
                    .fit_4_3 => .fill,
                    .fill => .fill,
                };
            },
            .sfx_volume => {
                self.editing.sfx_volume = @min(1.0, self.editing.sfx_volume + 0.1);
            },
            .music_volume => {
                self.editing.music_volume = @min(1.0, self.editing.music_volume + 0.1);
            },
            .accept, .cancel => {},
        }
    }

    /// Activate the currently selected item (Enter/click).
    /// Returns the result of the action.
    pub fn activate(self: *OptionsMenu) ClickResult {
        return switch (self.selected) {
            .accept => .accept,
            .cancel => .cancel,
            else => .none,
        };
    }

    /// Process a mouse click at framebuffer coordinates (x, y).
    /// Returns the result of the click action.
    pub fn handleClick(self: *OptionsMenu, x: u16, y: u16) ClickResult {
        // Check button area
        if (y >= LAYOUT.button_y and y < LAYOUT.button_y + 16) {
            if (x >= LAYOUT.accept_x and x < LAYOUT.accept_x + 50) {
                self.selected = .accept;
                return .accept;
            }
            if (x >= LAYOUT.cancel_x and x < LAYOUT.cancel_x + 50) {
                self.selected = .cancel;
                return .cancel;
            }
        }

        // Check option items
        for (0..5) |i| {
            const item_y = LAYOUT.first_item_y + @as(u16, @intCast(i)) * LAYOUT.item_height;
            if (y >= item_y and y < item_y + LAYOUT.item_height) {
                self.selected = @enumFromInt(i);
                // Check for left/right arrow clicks
                if (x < LAYOUT.value_x) {
                    // Clicked on the label area, just select
                } else if (x < LAYOUT.value_x + 40) {
                    // Clicked on value, adjust left
                    self.adjustLeft();
                } else {
                    // Clicked past value, adjust right
                    self.adjustRight();
                }
                return .none;
            }
        }

        return .none;
    }

    /// Render the options menu onto the framebuffer.
    /// Uses direct pixel drawing since we don't have a font in unit tests.
    /// The actual game will use Font.drawText for real text rendering.
    pub fn render(self: *const OptionsMenu, fb: *framebuffer_mod.Framebuffer) void {
        // Clear background
        fb.clear(COLOR.background);

        // Draw border
        drawRect(fb, LAYOUT.border_x, LAYOUT.border_y, LAYOUT.border_w, LAYOUT.border_h, COLOR.border);

        // Draw selection highlight bar
        const sel_y = itemY(self.selected);
        if (@intFromEnum(self.selected) < @intFromEnum(MenuItem.accept)) {
            fillRect(fb, LAYOUT.label_x - 2, sel_y, LAYOUT.border_w - 40, LAYOUT.item_height, COLOR.selected_bg);
        }

        // Draw volume bars for sfx and music
        self.renderVolumeBar(fb, .sfx_volume);
        self.renderVolumeBar(fb, .music_volume);
    }

    /// Render a volume bar for the given menu item.
    fn renderVolumeBar(self: *const OptionsMenu, fb: *framebuffer_mod.Framebuffer, item: MenuItem) void {
        const volume = switch (item) {
            .sfx_volume => self.editing.sfx_volume,
            .music_volume => self.editing.music_volume,
            else => return,
        };
        const y = itemY(item) + 8;
        const bar_x: u16 = LAYOUT.value_x;
        const bar_w: u16 = 80;
        const filled: u16 = @intFromFloat(@round(volume * @as(f32, @floatFromInt(bar_w))));

        // Background bar
        fillRect(fb, bar_x, y, bar_w, 4, COLOR.border);
        // Filled portion
        if (filled > 0) {
            fillRect(fb, bar_x, y, filled, 4, COLOR.value);
        }
    }

    /// Get the display string for the current value of a menu item.
    pub fn valueString(self: *const OptionsMenu, item: MenuItem) []const u8 {
        return switch (item) {
            .scale_factor => switch (self.editing.scale_factor) {
                .x2 => "2x (640x400)",
                .x3 => "3x (960x600)",
                .x4 => "4x (1280x800)",
            },
            .fullscreen => if (self.editing.fullscreen) "On" else "Off",
            .viewport_mode => switch (self.editing.viewport_mode) {
                .fit_4_3 => "4:3 (Original)",
                .fill => "Fill Window",
            },
            .sfx_volume => "", // Rendered as bar
            .music_volume => "", // Rendered as bar
            .accept => "Accept",
            .cancel => "Cancel",
        };
    }

    /// Get the label string for a menu item.
    pub fn labelString(item: MenuItem) []const u8 {
        return switch (item) {
            .scale_factor => "Resolution",
            .fullscreen => "Fullscreen",
            .viewport_mode => "Aspect Ratio",
            .sfx_volume => "SFX Volume",
            .music_volume => "Music Volume",
            .accept => "Accept",
            .cancel => "Cancel",
        };
    }
};

/// Draw a hollow rectangle outline.
fn drawRect(fb: *framebuffer_mod.Framebuffer, x: u16, y: u16, w: u16, h: u16, color: u8) void {
    // Top and bottom edges
    var i: u16 = 0;
    while (i < w) : (i += 1) {
        fb.setPixel(x + i, y, color);
        fb.setPixel(x + i, y + h - 1, color);
    }
    // Left and right edges
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

test "OptionsMenu init copies settings" {
    const s = settings_mod.Settings{
        .scale_factor = .x3,
        .fullscreen = true,
        .viewport_mode = .fill,
        .sfx_volume = 0.5,
        .music_volume = 0.3,
        .joystick_deadzone = 0.15,
    };
    const menu = OptionsMenu.init(s);
    try std.testing.expectEqual(upscale_mod.ScaleFactor.x3, menu.editing.scale_factor);
    try std.testing.expect(menu.editing.fullscreen);
    try std.testing.expectEqual(viewport.Mode.fill, menu.editing.viewport_mode);
    try std.testing.expectEqual(MenuItem.scale_factor, menu.selected);
}

test "OptionsMenu moveUp and moveDown" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    try std.testing.expectEqual(MenuItem.scale_factor, menu.selected);

    menu.moveDown();
    try std.testing.expectEqual(MenuItem.fullscreen, menu.selected);

    menu.moveDown();
    try std.testing.expectEqual(MenuItem.viewport_mode, menu.selected);

    menu.moveUp();
    try std.testing.expectEqual(MenuItem.fullscreen, menu.selected);

    // Can't go above first item
    menu.moveUp();
    menu.moveUp();
    try std.testing.expectEqual(MenuItem.scale_factor, menu.selected);
}

test "OptionsMenu moveDown stops at last item" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    // Move to the last item
    var i: u8 = 0;
    while (i < MenuItem.COUNT + 5) : (i += 1) {
        menu.moveDown();
    }
    try std.testing.expectEqual(MenuItem.cancel, menu.selected);
}

test "OptionsMenu adjustRight increases scale factor" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    menu.editing.scale_factor = .x2;
    menu.selected = .scale_factor;

    menu.adjustRight();
    try std.testing.expectEqual(upscale_mod.ScaleFactor.x3, menu.editing.scale_factor);

    menu.adjustRight();
    try std.testing.expectEqual(upscale_mod.ScaleFactor.x4, menu.editing.scale_factor);

    // Can't go above x4
    menu.adjustRight();
    try std.testing.expectEqual(upscale_mod.ScaleFactor.x4, menu.editing.scale_factor);
}

test "OptionsMenu adjustLeft decreases scale factor" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    menu.editing.scale_factor = .x4;
    menu.selected = .scale_factor;

    menu.adjustLeft();
    try std.testing.expectEqual(upscale_mod.ScaleFactor.x3, menu.editing.scale_factor);

    menu.adjustLeft();
    try std.testing.expectEqual(upscale_mod.ScaleFactor.x2, menu.editing.scale_factor);

    // Can't go below x2
    menu.adjustLeft();
    try std.testing.expectEqual(upscale_mod.ScaleFactor.x2, menu.editing.scale_factor);
}

test "OptionsMenu fullscreen toggle" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    menu.selected = .fullscreen;
    try std.testing.expect(!menu.editing.fullscreen);

    menu.adjustRight();
    try std.testing.expect(menu.editing.fullscreen);

    menu.adjustLeft();
    try std.testing.expect(!menu.editing.fullscreen);
}

test "OptionsMenu sfx volume adjusts by 0.1" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    menu.editing.sfx_volume = 0.5;
    menu.selected = .sfx_volume;

    menu.adjustRight();
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), menu.editing.sfx_volume, 0.01);

    menu.adjustLeft();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), menu.editing.sfx_volume, 0.01);
}

test "OptionsMenu volume clamps to 0-1" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    menu.selected = .sfx_volume;

    // Set to near max and try to exceed
    menu.editing.sfx_volume = 0.95;
    menu.adjustRight();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), menu.editing.sfx_volume, 0.01);

    // Set to near min and try to go below
    menu.editing.sfx_volume = 0.05;
    menu.adjustLeft();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), menu.editing.sfx_volume, 0.01);
}

test "OptionsMenu activate returns accept on accept item" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    menu.selected = .accept;
    try std.testing.expectEqual(ClickResult.accept, menu.activate());
}

test "OptionsMenu activate returns cancel on cancel item" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    menu.selected = .cancel;
    try std.testing.expectEqual(ClickResult.cancel, menu.activate());
}

test "OptionsMenu activate returns none on option items" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    menu.selected = .scale_factor;
    try std.testing.expectEqual(ClickResult.none, menu.activate());

    menu.selected = .sfx_volume;
    try std.testing.expectEqual(ClickResult.none, menu.activate());
}

test "OptionsMenu handleClick on accept button" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    const result = menu.handleClick(LAYOUT.accept_x + 10, LAYOUT.button_y + 5);
    try std.testing.expectEqual(ClickResult.accept, result);
    try std.testing.expectEqual(MenuItem.accept, menu.selected);
}

test "OptionsMenu handleClick on cancel button" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    const result = menu.handleClick(LAYOUT.cancel_x + 10, LAYOUT.button_y + 5);
    try std.testing.expectEqual(ClickResult.cancel, result);
    try std.testing.expectEqual(MenuItem.cancel, menu.selected);
}

test "OptionsMenu handleClick selects item row" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    // Click on the fullscreen row (item index 1)
    const y = LAYOUT.first_item_y + 1 * LAYOUT.item_height + 5;
    _ = menu.handleClick(LAYOUT.label_x + 5, y);
    try std.testing.expectEqual(MenuItem.fullscreen, menu.selected);
}

test "OptionsMenu render draws border and selection" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    var fb = framebuffer_mod.Framebuffer.create();

    menu.render(&fb);

    // Border top-left corner should be drawn
    try std.testing.expectEqual(COLOR.border, fb.getPixel(LAYOUT.border_x, LAYOUT.border_y));

    // Selection highlight bar should be drawn at first item
    const sel_y = LAYOUT.first_item_y;
    try std.testing.expectEqual(COLOR.selected_bg, fb.getPixel(LAYOUT.label_x, sel_y + 1));
}

test "OptionsMenu render draws volume bars" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    menu.editing.sfx_volume = 1.0;
    var fb = framebuffer_mod.Framebuffer.create();

    menu.render(&fb);

    // SFX volume bar should have filled pixels at full volume
    const sfx_y = LAYOUT.first_item_y + 3 * LAYOUT.item_height + 8;
    try std.testing.expectEqual(COLOR.value, fb.getPixel(LAYOUT.value_x + 5, sfx_y + 1));
}

test "OptionsMenu valueString returns correct strings" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    menu.editing.scale_factor = .x2;
    try std.testing.expectEqualStrings("2x (640x400)", menu.valueString(.scale_factor));

    menu.editing.scale_factor = .x4;
    try std.testing.expectEqualStrings("4x (1280x800)", menu.valueString(.scale_factor));

    menu.editing.fullscreen = false;
    try std.testing.expectEqualStrings("Off", menu.valueString(.fullscreen));

    menu.editing.fullscreen = true;
    try std.testing.expectEqualStrings("On", menu.valueString(.fullscreen));
}

test "OptionsMenu labelString returns correct labels" {
    try std.testing.expectEqualStrings("Resolution", OptionsMenu.labelString(.scale_factor));
    try std.testing.expectEqualStrings("Fullscreen", OptionsMenu.labelString(.fullscreen));
    try std.testing.expectEqualStrings("Aspect Ratio", OptionsMenu.labelString(.viewport_mode));
    try std.testing.expectEqualStrings("SFX Volume", OptionsMenu.labelString(.sfx_volume));
    try std.testing.expectEqualStrings("Music Volume", OptionsMenu.labelString(.music_volume));
}

test "OptionsMenu viewport_mode cycles" {
    var menu = OptionsMenu.init(settings_mod.Settings.defaults());
    menu.selected = .viewport_mode;
    try std.testing.expectEqual(viewport.Mode.fit_4_3, menu.editing.viewport_mode);

    menu.adjustRight();
    try std.testing.expectEqual(viewport.Mode.fill, menu.editing.viewport_mode);

    menu.adjustLeft();
    try std.testing.expectEqual(viewport.Mode.fit_4_3, menu.editing.viewport_mode);
}
