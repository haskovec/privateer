//! MFD (Multi-Function Display) system for Wing Commander: Privateer.
//!
//! Parses cockpit IFF data for MFD display areas (CMFD), instrument dials
//! (DIAL), and HUD overlay configuration (CHUD). Provides rendering of
//! gauge displays during space flight.
//!
//! Cockpit IFF shared elements (after directional views):
//!   FONT  - Font filename reference (e.g. "PRIVFNT\0")
//!   FORM:CMFD - MFD display areas
//!     FORM:AMFD (per display) - INFO (11 bytes: rect + index + params)
//!     SOFT - Software display font ref
//!   FORM:CHUD - HUD configuration
//!     HINF - HUD info bytes
//!     FORM:HSFT - HUD-shift modes (TRGT, CRSS, NAVI, etc.)
//!   FORM:DIAL - Instrument dials
//!     FORM:RADR - Radar rect
//!     FORM:SHLD - Shield display (rect + geometry + sprite)
//!     FORM:ENER - Energy gauge (VIEW sub-forms)
//!     FORM:FUEL - Fuel gauge (VIEW sub-forms)
//!     FORM:AUTO - Autopilot indicator (rect + sprite)
//!     FORM:SSPD - Set speed (rect + label)
//!     FORM:ASPD - Actual speed (rect + label)

const std = @import("std");
const iff = @import("../formats/iff.zig");
const framebuffer_mod = @import("../render/framebuffer.zig");

// ── Data types ──────────────────────────────────────────────────────────

/// Screen rectangle in 320x200 coordinates.
pub const Rect = struct {
    x1: u16,
    y1: u16,
    x2: u16,
    y2: u16,

    pub fn width(self: Rect) u16 {
        if (self.x2 <= self.x1) return 0;
        return self.x2 - self.x1;
    }

    pub fn height(self: Rect) u16 {
        if (self.y2 <= self.y1) return 0;
        return self.y2 - self.y1;
    }

    /// Parse a Rect from 8 bytes of little-endian u16 data.
    pub fn parse(data: []const u8) ?Rect {
        if (data.len < 8) return null;
        return Rect{
            .x1 = std.mem.readInt(u16, data[0..2], .little),
            .y1 = std.mem.readInt(u16, data[2..4], .little),
            .x2 = std.mem.readInt(u16, data[4..6], .little),
            .y2 = std.mem.readInt(u16, data[6..8], .little),
        };
    }
};

/// A single MFD display area (parsed from FORM:AMFD).
pub const MfdDisplay = struct {
    /// Screen rectangle where this MFD renders.
    rect: Rect,
    /// Display index (0=primary/left, 1=secondary/right, 2=tertiary).
    index: u8,
};

/// Speed display configuration (SSPD or ASPD).
pub const SpeedDisplay = struct {
    /// Screen rectangle for the speed readout.
    rect: Rect,
    /// Label text (e.g. "SET ", "KPS ").
    label: [8]u8,
    label_len: u8,

    pub fn labelSlice(self: *const SpeedDisplay) []const u8 {
        return self.label[0..self.label_len];
    }
};

/// Gauge view configuration (energy, fuel bars).
pub const GaugeView = struct {
    /// Screen rectangle for this gauge.
    rect: Rect,
};

/// All instrument dials parsed from FORM:DIAL.
pub const DialData = struct {
    radar_rect: ?Rect = null,
    shield_rect: ?Rect = null,
    energy: ?GaugeView = null,
    fuel: ?GaugeView = null,
    autopilot_rect: ?Rect = null,
    set_speed: ?SpeedDisplay = null,
    actual_speed: ?SpeedDisplay = null,
};

/// HUD-shift mode types (sub-forms of HSFT).
pub const HudMode = enum {
    targeting,
    crosshairs,
    navigation,
};

/// Complete MFD data parsed from a cockpit IFF.
pub const MfdData = struct {
    /// MFD display areas (up to 4 per cockpit).
    displays: [4]?MfdDisplay = .{ null, null, null, null },
    display_count: u8 = 0,
    /// Instrument dial data.
    dials: DialData = .{},
    /// Number of HUD-shift modes found.
    hud_mode_count: u8 = 0,
    /// Which HUD modes are available.
    hud_modes: [8]?HudMode = .{ null, null, null, null, null, null, null, null },
};

// ── MFD Display mode (runtime state) ───────────────────────────────────

/// MFD display modes that can be cycled through.
pub const DisplayMode = enum {
    navigation,
    weapons,
    damage,
    communications,
    cargo,
};

/// Runtime MFD state for a single display.
pub const MfdState = struct {
    current_mode: DisplayMode = .navigation,

    /// Cycle to the next display mode.
    pub fn cycleForward(self: *MfdState) void {
        self.current_mode = switch (self.current_mode) {
            .navigation => .weapons,
            .weapons => .damage,
            .damage => .communications,
            .communications => .cargo,
            .cargo => .navigation,
        };
    }

    /// Cycle to the previous display mode.
    pub fn cycleBackward(self: *MfdState) void {
        self.current_mode = switch (self.current_mode) {
            .navigation => .cargo,
            .weapons => .navigation,
            .damage => .weapons,
            .communications => .damage,
            .cargo => .communications,
        };
    }
};

// ── Parsing ─────────────────────────────────────────────────────────────

pub const MfdError = error{
    InvalidFormat,
    OutOfMemory,
};

/// Parse MFD data from a cockpit IFF root chunk (FORM:COCK).
/// Extracts CMFD, DIAL, and CHUD sub-forms.
pub fn parseMfdData(allocator: std.mem.Allocator, root: iff.Chunk) (MfdError || iff.IffError)!MfdData {
    _ = allocator;

    // Verify root is FORM:COCK
    if (!std.mem.eql(u8, &root.tag, "FORM") or root.form_type == null or
        !std.mem.eql(u8, &root.form_type.?, "COCK"))
    {
        return MfdError.InvalidFormat;
    }

    var result = MfdData{};

    // Parse CMFD
    if (root.findForm("CMFD".*)) |cmfd| {
        parseCmfd(&result, cmfd);
    }

    // Parse DIAL
    if (root.findForm("DIAL".*)) |dial| {
        parseDial(&result, dial);
    }

    // Parse CHUD
    if (root.findForm("CHUD".*)) |chud| {
        parseChud(&result, chud);
    }

    return result;
}

fn parseCmfd(result: *MfdData, cmfd: *const iff.Chunk) void {
    // Find AMFD sub-forms (one per MFD display area)
    for (cmfd.children) |*child| {
        if (std.mem.eql(u8, &child.tag, "FORM")) {
            if (child.form_type) |ft| {
                if (std.mem.eql(u8, &ft, "AMFD")) {
                    if (result.display_count < 4) {
                        if (parseAmfd(child)) |display| {
                            result.displays[result.display_count] = display;
                            result.display_count += 1;
                        }
                    }
                }
            }
        }
    }
}

fn parseAmfd(amfd: *const iff.Chunk) ?MfdDisplay {
    const info = amfd.findChild("INFO".*) orelse return null;
    if (info.data.len < 9) return null;

    const rect = Rect.parse(info.data) orelse return null;
    return MfdDisplay{
        .rect = rect,
        .index = info.data[8],
    };
}

fn parseDial(result: *MfdData, dial: *const iff.Chunk) void {
    // RADR
    if (dial.findForm("RADR".*)) |radr| {
        if (radr.findChild("INFO".*)) |info| {
            result.dials.radar_rect = Rect.parse(info.data);
        }
    }

    // SHLD
    if (dial.findForm("SHLD".*)) |shld| {
        if (shld.findChild("INFO".*)) |info| {
            result.dials.shield_rect = Rect.parse(info.data);
        }
    }

    // ENER - look for VIEW sub-form
    if (dial.findForm("ENER".*)) |ener| {
        if (ener.findForm("VIEW".*)) |view| {
            if (view.findChild("INFO".*)) |info| {
                result.dials.energy = GaugeView{
                    .rect = Rect.parse(info.data) orelse return,
                };
            }
        }
    }

    // FUEL - look for VIEW sub-form
    if (dial.findForm("FUEL".*)) |fuel| {
        if (fuel.findForm("VIEW".*)) |view| {
            if (view.findChild("INFO".*)) |info| {
                result.dials.fuel = GaugeView{
                    .rect = Rect.parse(info.data) orelse return,
                };
            }
        }
    }

    // AUTO
    if (dial.findForm("AUTO".*)) |auto_form| {
        if (auto_form.findChild("INFO".*)) |info| {
            result.dials.autopilot_rect = Rect.parse(info.data);
        }
    }

    // SSPD
    if (dial.findForm("SSPD".*)) |sspd| {
        result.dials.set_speed = parseSpeedDisplay(sspd);
    }

    // ASPD
    if (dial.findForm("ASPD".*)) |aspd| {
        result.dials.actual_speed = parseSpeedDisplay(aspd);
    }
}

fn parseSpeedDisplay(form: *const iff.Chunk) ?SpeedDisplay {
    const info = form.findChild("INFO".*) orelse return null;
    const rect = Rect.parse(info.data) orelse return null;

    var display = SpeedDisplay{
        .rect = rect,
        .label = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .label_len = 0,
    };

    // DATA chunk: 4 unknown bytes + null-terminated label string
    if (form.findChild("DATA".*)) |data_chunk| {
        if (data_chunk.data.len > 5) {
            // Skip first 4 bytes (unknown) and the 5th byte (possibly a key code)
            const label_start: usize = 5;
            const data = data_chunk.data;
            var len: u8 = 0;
            var i: usize = label_start;
            while (i < data.len and data[i] != 0 and len < 8) : (i += 1) {
                display.label[len] = data[i];
                len += 1;
            }
            display.label_len = len;
        }
    }

    return display;
}

fn parseChud(result: *MfdData, chud: *const iff.Chunk) void {
    if (chud.findForm("HSFT".*)) |hsft| {
        for (hsft.children) |*child| {
            if (std.mem.eql(u8, &child.tag, "FORM")) {
                if (child.form_type) |ft| {
                    const mode: ?HudMode = if (std.mem.eql(u8, &ft, "TRGT"))
                        .targeting
                    else if (std.mem.eql(u8, &ft, "CRSS"))
                        .crosshairs
                    else if (std.mem.eql(u8, &ft, "NAVI"))
                        .navigation
                    else
                        null;

                    if (mode) |m| {
                        if (result.hud_mode_count < 8) {
                            result.hud_modes[result.hud_mode_count] = m;
                            result.hud_mode_count += 1;
                        }
                    }
                }
            }
        }
    }
}

// ── Rendering ───────────────────────────────────────────────────────────

/// Fill a rectangle on the framebuffer with a solid color.
pub fn fillRect(fb: *framebuffer_mod.Framebuffer, rect: Rect, color: u8) void {
    const x_start: u16 = rect.x1;
    const x_end: u16 = rect.x2;
    const y_start: u16 = rect.y1;
    const y_end: u16 = rect.y2;

    var y: u16 = y_start;
    while (y < y_end) : (y += 1) {
        var x: u16 = x_start;
        while (x < x_end) : (x += 1) {
            fb.setPixel(x, y, color);
        }
    }
}

/// Draw an outlined rectangle on the framebuffer.
pub fn drawRect(fb: *framebuffer_mod.Framebuffer, rect: Rect, color: u8) void {
    // Top and bottom edges
    var x: u16 = rect.x1;
    while (x < rect.x2) : (x += 1) {
        fb.setPixel(x, rect.y1, color);
        if (rect.y2 > 0) fb.setPixel(x, rect.y2 - 1, color);
    }
    // Left and right edges
    var y: u16 = rect.y1;
    while (y < rect.y2) : (y += 1) {
        fb.setPixel(rect.x1, y, color);
        if (rect.x2 > 0) fb.setPixel(rect.x2 - 1, y, color);
    }
}

/// Render a horizontal gauge bar (e.g. fuel, energy).
/// fill_fraction is 0.0 (empty) to 1.0 (full).
/// The bar fills from left to right within the given rect.
pub fn renderGaugeBar(
    fb: *framebuffer_mod.Framebuffer,
    rect: Rect,
    fill_fraction: f32,
    filled_color: u8,
    empty_color: u8,
) void {
    const w = rect.width();
    const clamped = std.math.clamp(fill_fraction, 0.0, 1.0);
    const fill_width: u16 = @intFromFloat(@as(f32, @floatFromInt(w)) * clamped);

    var y: u16 = rect.y1;
    while (y < rect.y2) : (y += 1) {
        var x: u16 = rect.x1;
        while (x < rect.x2) : (x += 1) {
            const dx = x - rect.x1;
            fb.setPixel(x, y, if (dx < fill_width) filled_color else empty_color);
        }
    }
}

/// Render a speed value as a 3-digit number at the given rect position.
/// Writes digits directly to the framebuffer using simple built-in glyphs.
pub fn renderSpeedText(
    fb: *framebuffer_mod.Framebuffer,
    x: u16,
    y: u16,
    value: u32,
    color: u8,
) void {
    // Simple 3x5 digit glyphs (each row is a 3-bit pattern)
    const digit_patterns = [10][5]u3{
        .{ 0b111, 0b101, 0b101, 0b101, 0b111 }, // 0
        .{ 0b010, 0b110, 0b010, 0b010, 0b111 }, // 1
        .{ 0b111, 0b001, 0b111, 0b100, 0b111 }, // 2
        .{ 0b111, 0b001, 0b111, 0b001, 0b111 }, // 3
        .{ 0b101, 0b101, 0b111, 0b001, 0b001 }, // 4
        .{ 0b111, 0b100, 0b111, 0b001, 0b111 }, // 5
        .{ 0b111, 0b100, 0b111, 0b101, 0b111 }, // 6
        .{ 0b111, 0b001, 0b010, 0b010, 0b010 }, // 7
        .{ 0b111, 0b101, 0b111, 0b101, 0b111 }, // 8
        .{ 0b111, 0b101, 0b111, 0b001, 0b111 }, // 9
    };

    const clamped = @min(value, 999);
    const digits = [3]u32{
        clamped / 100,
        (clamped / 10) % 10,
        clamped % 10,
    };

    for (digits, 0..) |d, di| {
        const pattern = digit_patterns[d];
        for (pattern, 0..) |row, ry| {
            const px_x = x + @as(u16, @intCast(di)) * 4;
            const px_y = y + @as(u16, @intCast(ry));
            if (row & 0b100 != 0) fb.setPixel(px_x, px_y, color);
            if (row & 0b010 != 0) fb.setPixel(px_x + 1, px_y, color);
            if (row & 0b001 != 0) fb.setPixel(px_x + 2, px_y, color);
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

test "Rect.parse extracts 4 u16 LE values" {
    const data = [8]u8{ 0x24, 0x00, 0x06, 0x00, 0x73, 0x00, 0x46, 0x00 };
    const rect = Rect.parse(&data).?;
    try std.testing.expectEqual(@as(u16, 36), rect.x1);
    try std.testing.expectEqual(@as(u16, 6), rect.y1);
    try std.testing.expectEqual(@as(u16, 115), rect.x2);
    try std.testing.expectEqual(@as(u16, 70), rect.y2);
    try std.testing.expectEqual(@as(u16, 79), rect.width());
    try std.testing.expectEqual(@as(u16, 64), rect.height());
}

test "Rect.parse returns null for short data" {
    const data = [4]u8{ 0x24, 0x00, 0x06, 0x00 };
    try std.testing.expect(Rect.parse(&data) == null);
}

test "parseMfdData extracts CMFD display areas" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_mfd.bin");
    defer allocator.free(data);

    var root = try iff.parseFile(allocator, data);
    defer root.deinit();

    const mfd = try parseMfdData(allocator, root);

    // Should find 2 AMFD displays (left and right)
    try std.testing.expectEqual(@as(u8, 2), mfd.display_count);

    // Left MFD: rect(36, 6, 115, 70), index=0
    const left = mfd.displays[0].?;
    try std.testing.expectEqual(@as(u16, 36), left.rect.x1);
    try std.testing.expectEqual(@as(u16, 6), left.rect.y1);
    try std.testing.expectEqual(@as(u16, 115), left.rect.x2);
    try std.testing.expectEqual(@as(u16, 70), left.rect.y2);
    try std.testing.expectEqual(@as(u8, 0), left.index);

    // Right MFD: rect(180, 6, 259, 70), index=1
    const right = mfd.displays[1].?;
    try std.testing.expectEqual(@as(u16, 180), right.rect.x1);
    try std.testing.expectEqual(@as(u16, 6), right.rect.y1);
    try std.testing.expectEqual(@as(u16, 259), right.rect.x2);
    try std.testing.expectEqual(@as(u16, 70), right.rect.y2);
    try std.testing.expectEqual(@as(u8, 1), right.index);
}

test "parseMfdData extracts DIAL radar rect" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_mfd.bin");
    defer allocator.free(data);

    var root = try iff.parseFile(allocator, data);
    defer root.deinit();

    const mfd = try parseMfdData(allocator, root);

    // Radar: rect(90, 126, 138, 162) = 48x36 pixels
    const radar = mfd.dials.radar_rect.?;
    try std.testing.expectEqual(@as(u16, 90), radar.x1);
    try std.testing.expectEqual(@as(u16, 126), radar.y1);
    try std.testing.expectEqual(@as(u16, 138), radar.x2);
    try std.testing.expectEqual(@as(u16, 162), radar.y2);
    try std.testing.expectEqual(@as(u16, 48), radar.width());
    try std.testing.expectEqual(@as(u16, 36), radar.height());
}

test "parseMfdData extracts DIAL shield rect" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_mfd.bin");
    defer allocator.free(data);

    var root = try iff.parseFile(allocator, data);
    defer root.deinit();

    const mfd = try parseMfdData(allocator, root);

    const shield = mfd.dials.shield_rect.?;
    try std.testing.expectEqual(@as(u16, 170), shield.x1);
    try std.testing.expectEqual(@as(u16, 126), shield.y1);
    try std.testing.expectEqual(@as(u16, 218), shield.x2);
    try std.testing.expectEqual(@as(u16, 162), shield.y2);
}

test "parseMfdData extracts energy gauge" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_mfd.bin");
    defer allocator.free(data);

    var root = try iff.parseFile(allocator, data);
    defer root.deinit();

    const mfd = try parseMfdData(allocator, root);

    const energy = mfd.dials.energy.?;
    try std.testing.expectEqual(@as(u16, 155), energy.rect.x1);
    try std.testing.expectEqual(@as(u16, 35), energy.rect.y1);
    try std.testing.expectEqual(@as(u16, 168), energy.rect.x2);
    try std.testing.expectEqual(@as(u16, 59), energy.rect.y2);
}

test "parseMfdData extracts fuel gauge" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_mfd.bin");
    defer allocator.free(data);

    var root = try iff.parseFile(allocator, data);
    defer root.deinit();

    const mfd = try parseMfdData(allocator, root);

    const fuel = mfd.dials.fuel.?;
    try std.testing.expectEqual(@as(u16, 143), fuel.rect.x1);
    try std.testing.expectEqual(@as(u16, 3), fuel.rect.y1);
    try std.testing.expectEqual(@as(u16, 180), fuel.rect.x2);
    try std.testing.expectEqual(@as(u16, 8), fuel.rect.y2);
}

test "parseMfdData extracts autopilot rect" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_mfd.bin");
    defer allocator.free(data);

    var root = try iff.parseFile(allocator, data);
    defer root.deinit();

    const mfd = try parseMfdData(allocator, root);

    const auto = mfd.dials.autopilot_rect.?;
    try std.testing.expectEqual(@as(u16, 146), auto.x1);
    try std.testing.expectEqual(@as(u16, 14), auto.y1);
    try std.testing.expectEqual(@as(u16, 177), auto.x2);
    try std.testing.expectEqual(@as(u16, 19), auto.y2);
}

test "parseMfdData extracts speed displays with labels" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_mfd.bin");
    defer allocator.free(data);

    var root = try iff.parseFile(allocator, data);
    defer root.deinit();

    const mfd = try parseMfdData(allocator, root);

    // Set speed
    const sspd = mfd.dials.set_speed.?;
    try std.testing.expectEqual(@as(u16, 50), sspd.rect.x1);
    try std.testing.expectEqual(@as(u16, 130), sspd.rect.y1);
    try std.testing.expectEqual(@as(u16, 81), sspd.rect.x2);
    try std.testing.expectEqual(@as(u16, 135), sspd.rect.y2);
    try std.testing.expectEqualStrings("SET ", sspd.labelSlice());

    // Actual speed
    const aspd = mfd.dials.actual_speed.?;
    try std.testing.expectEqual(@as(u16, 50), aspd.rect.x1);
    try std.testing.expectEqual(@as(u16, 140), aspd.rect.y1);
    try std.testing.expectEqual(@as(u16, 81), aspd.rect.x2);
    try std.testing.expectEqual(@as(u16, 144), aspd.rect.y2);
    try std.testing.expectEqualStrings("KPS ", aspd.labelSlice());
}

test "parseMfdData extracts CHUD HUD modes" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_mfd.bin");
    defer allocator.free(data);

    var root = try iff.parseFile(allocator, data);
    defer root.deinit();

    const mfd = try parseMfdData(allocator, root);

    // Should find 3 HUD modes: TRGT, CRSS, NAVI
    try std.testing.expectEqual(@as(u8, 3), mfd.hud_mode_count);
    try std.testing.expectEqual(HudMode.targeting, mfd.hud_modes[0].?);
    try std.testing.expectEqual(HudMode.crosshairs, mfd.hud_modes[1].?);
    try std.testing.expectEqual(HudMode.navigation, mfd.hud_modes[2].?);
}

test "parseMfdData rejects non-COCK IFF" {
    const data = [_]u8{
        'F', 'O', 'R', 'M',
        0, 0, 0, 4,
        'X', 'X', 'X', 'X',
    };
    try std.testing.expectError(
        MfdError.InvalidFormat,
        parseMfdData(std.testing.allocator, iff.Chunk{
            .tag = "FORM".*,
            .size = 4,
            .data = data[8..12],
            .form_type = "XXXX".*,
            .children = &.{},
            .allocator = std.testing.allocator,
        }),
    );
}

test "MfdState cycles forward through all modes" {
    var state = MfdState{};
    try std.testing.expectEqual(DisplayMode.navigation, state.current_mode);

    state.cycleForward();
    try std.testing.expectEqual(DisplayMode.weapons, state.current_mode);

    state.cycleForward();
    try std.testing.expectEqual(DisplayMode.damage, state.current_mode);

    state.cycleForward();
    try std.testing.expectEqual(DisplayMode.communications, state.current_mode);

    state.cycleForward();
    try std.testing.expectEqual(DisplayMode.cargo, state.current_mode);

    state.cycleForward();
    try std.testing.expectEqual(DisplayMode.navigation, state.current_mode);
}

test "MfdState cycles backward" {
    var state = MfdState{};
    state.cycleBackward();
    try std.testing.expectEqual(DisplayMode.cargo, state.current_mode);

    state.cycleBackward();
    try std.testing.expectEqual(DisplayMode.communications, state.current_mode);
}

test "fillRect fills correct pixels" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(0);

    const rect = Rect{ .x1 = 10, .y1 = 20, .x2 = 14, .y2 = 23 };
    fillRect(&fb, rect, 42);

    // Inside rect
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(10, 20));
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(13, 22));
    // Outside rect
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(9, 20));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(14, 20));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(10, 23));
}

test "drawRect draws border only" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(0);

    const rect = Rect{ .x1 = 10, .y1 = 10, .x2 = 15, .y2 = 15 };
    drawRect(&fb, rect, 7);

    // Top edge
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(10, 10));
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(14, 10));
    // Bottom edge
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(10, 14));
    // Left edge
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(10, 12));
    // Right edge
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(14, 12));
    // Interior should be empty
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(12, 12));
}

test "renderGaugeBar at 50% fills half" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(0);

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 2 };
    renderGaugeBar(&fb, rect, 0.5, 32, 16);

    // First 5 pixels = filled color
    try std.testing.expectEqual(@as(u8, 32), fb.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 32), fb.getPixel(4, 0));
    // Last 5 pixels = empty color
    try std.testing.expectEqual(@as(u8, 16), fb.getPixel(5, 0));
    try std.testing.expectEqual(@as(u8, 16), fb.getPixel(9, 0));
}

test "renderGaugeBar clamps to 0-1 range" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(0);

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 1 };

    // Overfill
    renderGaugeBar(&fb, rect, 1.5, 32, 16);
    try std.testing.expectEqual(@as(u8, 32), fb.getPixel(3, 0));

    // Underfill
    renderGaugeBar(&fb, rect, -0.5, 32, 16);
    try std.testing.expectEqual(@as(u8, 16), fb.getPixel(0, 0));
}

test "renderSpeedText draws digit pixels" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(0);

    renderSpeedText(&fb, 10, 10, 123, 7);

    // Check that some pixels are set (digit "1" starts at x=10)
    // Digit "1" row 0: 010 -> pixel at (11, 10) should be set
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(11, 10));
    // Digit "2" starts at x=14, row 0: 111 -> pixel at (14, 10)
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(14, 10));
}

test "renderSpeedText clamps to 999" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(0);

    // Should not crash with large value
    renderSpeedText(&fb, 10, 10, 5000, 7);

    // Should display 999: digit "9" at x=10, row 0: 111
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(10, 10));
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(11, 10));
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(12, 10));
}
