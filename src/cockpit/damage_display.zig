//! Damage display for Wing Commander: Privateer.
//!
//! Renders a ship damage diagram showing shield and armor status per facing
//! (front, rear, left, right). Displayed in the SHLD dial area of the cockpit
//! and as the "damage" MFD page.
//!
//! The display draws a schematic ship silhouette with color-coded shield bars
//! around it and armor bars inside. Colors transition from green (full) through
//! yellow (moderate) to red (critical) as damage accumulates.
//!
//! IFF data sources:
//!   FORM:DAMG > DAMG (4 bytes): max_value (u16 LE), num_layers (u16 LE)
//!   FORM:DIAL > FORM:SHLD > INFO: display rect (4x u16 LE)

const std = @import("std");
const mfd = @import("mfd.zig");
const framebuffer_mod = @import("../render/framebuffer.zig");
const iff = @import("../formats/iff.zig");

const Rect = mfd.Rect;

/// Per-facing damage state.
pub const FacingStatus = struct {
    /// Shield strength 0.0 (destroyed) to 1.0 (full).
    shield: f32 = 1.0,
    /// Armor strength 0.0 (destroyed) to 1.0 (full).
    armor: f32 = 1.0,
};

/// Complete damage status for all four ship facings.
pub const DamageStatus = struct {
    front: FacingStatus = .{},
    rear: FacingStatus = .{},
    left: FacingStatus = .{},
    right: FacingStatus = .{},

    /// Create a fully undamaged status.
    pub fn full() DamageStatus {
        return .{};
    }

    /// Create a status with all shields/armor at zero.
    pub fn destroyed() DamageStatus {
        return .{
            .front = .{ .shield = 0, .armor = 0 },
            .rear = .{ .shield = 0, .armor = 0 },
            .left = .{ .shield = 0, .armor = 0 },
            .right = .{ .shield = 0, .armor = 0 },
        };
    }
};

/// Configuration parsed from the DAMG IFF chunk.
pub const DamageConfig = struct {
    /// Maximum shield/armor value (typically 100).
    max_value: u16 = 100,
    /// Number of shield layers (typically 2 = front/back).
    num_layers: u16 = 2,
};

/// Palette color indices for damage display elements.
pub const DamageColors = struct {
    background: u8 = 0,
    /// Shield at full strength (green).
    shield_full: u8 = 47,
    /// Shield at moderate strength (yellow).
    shield_moderate: u8 = 43,
    /// Shield at critical strength (red).
    shield_critical: u8 = 32,
    /// Shield destroyed (dark).
    shield_empty: u8 = 2,
    /// Armor at full strength (bright green).
    armor_full: u8 = 47,
    /// Armor at moderate strength (yellow).
    armor_moderate: u8 = 43,
    /// Armor at critical strength (red).
    armor_critical: u8 = 32,
    /// Armor destroyed (dark).
    armor_empty: u8 = 2,
    /// Ship silhouette outline.
    ship_outline: u8 = 15,
};

/// Damage display renderer.
pub const DamageDisplay = struct {
    /// Screen rectangle (from DIAL SHLD INFO).
    rect: Rect,
    /// DAMG configuration.
    config: DamageConfig,
    /// Palette color indices.
    colors: DamageColors,

    /// Create a damage display with the given rect.
    pub fn init(rect: Rect) DamageDisplay {
        return .{
            .rect = rect,
            .config = .{},
            .colors = .{},
        };
    }

    /// Create a damage display with rect and parsed config.
    pub fn initWithConfig(rect: Rect, config: DamageConfig) DamageDisplay {
        return .{
            .rect = rect,
            .config = config,
            .colors = .{},
        };
    }

    /// Pick the color for a shield value (0.0 to 1.0).
    fn shieldColor(self: *const DamageDisplay, value: f32) u8 {
        if (value <= 0.0) return self.colors.shield_empty;
        if (value < 0.34) return self.colors.shield_critical;
        if (value < 0.67) return self.colors.shield_moderate;
        return self.colors.shield_full;
    }

    /// Pick the color for an armor value (0.0 to 1.0).
    fn armorColor(self: *const DamageDisplay, value: f32) u8 {
        if (value <= 0.0) return self.colors.armor_empty;
        if (value < 0.34) return self.colors.armor_critical;
        if (value < 0.67) return self.colors.armor_moderate;
        return self.colors.armor_full;
    }

    /// Render the damage display onto the framebuffer.
    ///
    /// Layout within the rect:
    ///   - Center: ship silhouette (small diamond)
    ///   - Top bar: front shield, inner top: front armor
    ///   - Bottom bar: rear shield, inner bottom: rear armor
    ///   - Left bar: left shield, inner left: left armor
    ///   - Right bar: right shield, inner right: right armor
    pub fn render(
        self: *const DamageDisplay,
        fb: *framebuffer_mod.Framebuffer,
        status: *const DamageStatus,
    ) void {
        const w = self.rect.width();
        const h = self.rect.height();
        if (w == 0 or h == 0) return;

        // Fill background
        mfd.fillRect(fb, self.rect, self.colors.background);

        const x1 = self.rect.x1;
        const y1 = self.rect.y1;

        // Divide the rect into regions:
        // Outer ring = shield bars (3 pixels wide)
        // Inner area = armor bars + ship silhouette
        const bar_w: u16 = 3;
        if (w < bar_w * 4 or h < bar_w * 4) return;

        // Shield bars (outer edge)
        // Front shield (top bar)
        const front_shield = Rect{
            .x1 = x1 + bar_w,
            .y1 = y1,
            .x2 = x1 + w - bar_w,
            .y2 = y1 + bar_w,
        };
        mfd.fillRect(fb, front_shield, self.shieldColor(status.front.shield));

        // Rear shield (bottom bar)
        const rear_shield = Rect{
            .x1 = x1 + bar_w,
            .y1 = y1 + h - bar_w,
            .x2 = x1 + w - bar_w,
            .y2 = y1 + h,
        };
        mfd.fillRect(fb, rear_shield, self.shieldColor(status.rear.shield));

        // Left shield (left bar)
        const left_shield = Rect{
            .x1 = x1,
            .y1 = y1 + bar_w,
            .x2 = x1 + bar_w,
            .y2 = y1 + h - bar_w,
        };
        mfd.fillRect(fb, left_shield, self.shieldColor(status.left.shield));

        // Right shield (right bar)
        const right_shield = Rect{
            .x1 = x1 + w - bar_w,
            .y1 = y1 + bar_w,
            .x2 = x1 + w,
            .y2 = y1 + h - bar_w,
        };
        mfd.fillRect(fb, right_shield, self.shieldColor(status.right.shield));

        // Armor bars (inner ring, 2 pixels wide, inset from shield bars)
        const armor_w: u16 = 2;
        const inner_x1 = x1 + bar_w + 1;
        const inner_y1 = y1 + bar_w + 1;
        const inner_x2 = x1 + w - bar_w - 1;
        const inner_y2 = y1 + h - bar_w - 1;

        if (inner_x2 <= inner_x1 + armor_w * 2 or inner_y2 <= inner_y1 + armor_w * 2) return;

        // Front armor (top inner bar)
        mfd.fillRect(fb, Rect{
            .x1 = inner_x1 + armor_w,
            .y1 = inner_y1,
            .x2 = inner_x2 - armor_w,
            .y2 = inner_y1 + armor_w,
        }, self.armorColor(status.front.armor));

        // Rear armor (bottom inner bar)
        mfd.fillRect(fb, Rect{
            .x1 = inner_x1 + armor_w,
            .y1 = inner_y2 - armor_w,
            .x2 = inner_x2 - armor_w,
            .y2 = inner_y2,
        }, self.armorColor(status.rear.armor));

        // Left armor (left inner bar)
        mfd.fillRect(fb, Rect{
            .x1 = inner_x1,
            .y1 = inner_y1 + armor_w,
            .x2 = inner_x1 + armor_w,
            .y2 = inner_y2 - armor_w,
        }, self.armorColor(status.left.armor));

        // Right armor (right inner bar)
        mfd.fillRect(fb, Rect{
            .x1 = inner_x2 - armor_w,
            .y1 = inner_y1 + armor_w,
            .x2 = inner_x2,
            .y2 = inner_y2 - armor_w,
        }, self.armorColor(status.right.armor));

        // Ship silhouette (diamond shape in the center)
        const cx = inner_x1 + (inner_x2 - inner_x1) / 2;
        const cy = inner_y1 + (inner_y2 - inner_y1) / 2;
        const ship_half_w = (inner_x2 - inner_x1) / 6;
        const ship_half_h = (inner_y2 - inner_y1) / 4;

        if (ship_half_w > 0 and ship_half_h > 0) {
            // Draw diamond: top, right, bottom, left points
            drawLine(fb, cx, cy -| ship_half_h, cx + ship_half_w, cy, self.colors.ship_outline);
            drawLine(fb, cx + ship_half_w, cy, cx, cy + ship_half_h, self.colors.ship_outline);
            drawLine(fb, cx, cy + ship_half_h, cx -| ship_half_w, cy, self.colors.ship_outline);
            drawLine(fb, cx -| ship_half_w, cy, cx, cy -| ship_half_h, self.colors.ship_outline);
        }
    }
};

/// Draw a line between two points using Bresenham's algorithm.
fn drawLine(fb: *framebuffer_mod.Framebuffer, x0: u16, y0: u16, x1: u16, y1: u16, color: u8) void {
    var px: i32 = @intCast(x0);
    var py: i32 = @intCast(y0);
    const ex: i32 = @intCast(x1);
    const ey: i32 = @intCast(y1);

    const dx: i32 = @intCast(@as(u32, if (ex > px) @intCast(ex - px) else @intCast(px - ex)));
    const dy: i32 = -@as(i32, @intCast(@as(u32, if (ey > py) @intCast(ey - py) else @intCast(py - ey))));
    const sx: i32 = if (px < ex) 1 else -1;
    const sy: i32 = if (py < ey) 1 else -1;
    var err = dx + dy;

    while (true) {
        if (px >= 0 and py >= 0) {
            fb.setPixel(@intCast(px), @intCast(py), color);
        }
        if (px == ex and py == ey) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            px += sx;
        }
        if (e2 <= dx) {
            err += dx;
            py += sy;
        }
    }
}

/// Parse DAMG configuration from a FORM:DAMG chunk.
pub fn parseDamageConfig(damg_form: *const iff.Chunk) ?DamageConfig {
    // Look for DAMG leaf chunk inside the FORM:DAMG
    const damg_chunk = damg_form.findChild("DAMG".*) orelse return null;
    if (damg_chunk.data.len < 4) return null;

    return DamageConfig{
        .max_value = std.mem.readInt(u16, damg_chunk.data[0..2], .little),
        .num_layers = std.mem.readInt(u16, damg_chunk.data[2..4], .little),
    };
}

/// Parse damage display data from a cockpit IFF root chunk (FORM:COCK).
/// Returns a DamageDisplay if both SHLD rect and DAMG config are found.
pub fn parseDamageDisplay(root: iff.Chunk) ?DamageDisplay {
    // Get shield rect from DIAL > SHLD > INFO
    var rect: ?Rect = null;
    if (root.findForm("DIAL".*)) |dial| {
        if (dial.findForm("SHLD".*)) |shld| {
            if (shld.findChild("INFO".*)) |info| {
                rect = Rect.parse(info.data);
            }
        }
    }

    const shield_rect = rect orelse return null;

    // Get DAMG config
    var config = DamageConfig{};
    if (root.findForm("DAMG".*)) |damg_form| {
        if (parseDamageConfig(damg_form)) |cfg| {
            config = cfg;
        }
    }

    return DamageDisplay.initWithConfig(shield_rect, config);
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

test "DamageStatus.full returns all shields and armor at 1.0" {
    const status = DamageStatus.full();
    try std.testing.expectEqual(@as(f32, 1.0), status.front.shield);
    try std.testing.expectEqual(@as(f32, 1.0), status.front.armor);
    try std.testing.expectEqual(@as(f32, 1.0), status.rear.shield);
    try std.testing.expectEqual(@as(f32, 1.0), status.rear.armor);
    try std.testing.expectEqual(@as(f32, 1.0), status.left.shield);
    try std.testing.expectEqual(@as(f32, 1.0), status.left.armor);
    try std.testing.expectEqual(@as(f32, 1.0), status.right.shield);
    try std.testing.expectEqual(@as(f32, 1.0), status.right.armor);
}

test "DamageStatus.destroyed returns all at zero" {
    const status = DamageStatus.destroyed();
    try std.testing.expectEqual(@as(f32, 0.0), status.front.shield);
    try std.testing.expectEqual(@as(f32, 0.0), status.front.armor);
    try std.testing.expectEqual(@as(f32, 0.0), status.rear.shield);
    try std.testing.expectEqual(@as(f32, 0.0), status.rear.armor);
}

test "DamageDisplay.init creates display with default config" {
    const rect = Rect{ .x1 = 170, .y1 = 126, .x2 = 218, .y2 = 162 };
    const display = DamageDisplay.init(rect);
    try std.testing.expectEqual(@as(u16, 170), display.rect.x1);
    try std.testing.expectEqual(@as(u16, 100), display.config.max_value);
}

test "DamageDisplay.initWithConfig stores custom config" {
    const rect = Rect{ .x1 = 10, .y1 = 10, .x2 = 60, .y2 = 60 };
    const config = DamageConfig{ .max_value = 200, .num_layers = 4 };
    const display = DamageDisplay.initWithConfig(rect, config);
    try std.testing.expectEqual(@as(u16, 200), display.config.max_value);
    try std.testing.expectEqual(@as(u16, 4), display.config.num_layers);
}

test "damage display shows full shields when undamaged" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(99);

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 48, .y2 = 36 };
    const display = DamageDisplay.init(rect);
    const status = DamageStatus.full();

    display.render(&fb, &status);

    // Background inside rect should be filled (not 99)
    // Shield bars should use full color (47 = green)
    // Front shield bar: top row, middle columns
    try std.testing.expectEqual(@as(u8, 47), fb.getPixel(10, 1)); // front shield (top bar)
    try std.testing.expectEqual(@as(u8, 47), fb.getPixel(10, 34)); // rear shield (bottom bar)
    try std.testing.expectEqual(@as(u8, 47), fb.getPixel(1, 18)); // left shield (left bar)
    try std.testing.expectEqual(@as(u8, 47), fb.getPixel(46, 18)); // right shield (right bar)

    // Outside rect should be untouched
    try std.testing.expectEqual(@as(u8, 99), fb.getPixel(48, 0));
    try std.testing.expectEqual(@as(u8, 99), fb.getPixel(0, 36));
}

test "damage display shows red for critical shields" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 48, .y2 = 36 };
    const display = DamageDisplay.init(rect);
    const status = DamageStatus{
        .front = .{ .shield = 0.1, .armor = 1.0 },
        .rear = .{ .shield = 1.0, .armor = 1.0 },
        .left = .{ .shield = 1.0, .armor = 1.0 },
        .right = .{ .shield = 1.0, .armor = 1.0 },
    };

    display.render(&fb, &status);

    // Front shield should be critical color (32 = red)
    try std.testing.expectEqual(@as(u8, 32), fb.getPixel(10, 1));
    // Rear shield should still be full (47 = green)
    try std.testing.expectEqual(@as(u8, 47), fb.getPixel(10, 34));
}

test "damage display shows empty color for destroyed shields" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 48, .y2 = 36 };
    const display = DamageDisplay.init(rect);
    const status = DamageStatus{
        .front = .{ .shield = 0.0, .armor = 1.0 },
        .rear = .{ .shield = 1.0, .armor = 1.0 },
        .left = .{ .shield = 1.0, .armor = 1.0 },
        .right = .{ .shield = 1.0, .armor = 1.0 },
    };

    display.render(&fb, &status);

    // Front shield should be empty color (2 = dark)
    try std.testing.expectEqual(@as(u8, 2), fb.getPixel(10, 1));
}

test "damage display renders yellow for moderate damage" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 48, .y2 = 36 };
    const display = DamageDisplay.init(rect);
    const status = DamageStatus{
        .front = .{ .shield = 0.5, .armor = 1.0 },
        .rear = .{ .shield = 1.0, .armor = 1.0 },
        .left = .{ .shield = 1.0, .armor = 1.0 },
        .right = .{ .shield = 1.0, .armor = 1.0 },
    };

    display.render(&fb, &status);

    // Front shield should be moderate color (43 = yellow)
    try std.testing.expectEqual(@as(u8, 43), fb.getPixel(10, 1));
}

test "damage display renders ship silhouette outline" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(0);

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 48, .y2 = 36 };
    const display = DamageDisplay.init(rect);
    const status = DamageStatus.full();

    display.render(&fb, &status);

    // The ship silhouette (color 15) should appear somewhere in the center area
    // Center of the inner area is around (24, 18)
    var has_outline = false;
    var y: u16 = 8;
    while (y < 28) : (y += 1) {
        var x: u16 = 8;
        while (x < 40) : (x += 1) {
            if (fb.getPixel(x, y) == 15) {
                has_outline = true;
                break;
            }
        }
        if (has_outline) break;
    }
    try std.testing.expect(has_outline);
}

test "damage display with offset rect positions correctly" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(99);

    // Simulate actual game rect (Tarsus shield area)
    const rect = Rect{ .x1 = 170, .y1 = 126, .x2 = 218, .y2 = 162 };
    const display = DamageDisplay.init(rect);
    const status = DamageStatus.full();

    display.render(&fb, &status);

    // Background filled inside rect
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(170, 126));
    // Shield bar inside rect
    try std.testing.expectEqual(@as(u8, 47), fb.getPixel(185, 127)); // front shield
    // Outside rect untouched
    try std.testing.expectEqual(@as(u8, 99), fb.getPixel(169, 126));
    try std.testing.expectEqual(@as(u8, 99), fb.getPixel(218, 126));
}

test "damage display with zero-size rect is no-op" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(99);

    const rect = Rect{ .x1 = 10, .y1 = 10, .x2 = 10, .y2 = 10 };
    const display = DamageDisplay.init(rect);
    const status = DamageStatus.full();

    display.render(&fb, &status);

    // Nothing should change
    try std.testing.expectEqual(@as(u8, 99), fb.getPixel(10, 10));
}

test "damage display armor bars use correct colors" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 48, .y2 = 36 };
    const display = DamageDisplay.init(rect);
    const status = DamageStatus{
        .front = .{ .shield = 1.0, .armor = 0.2 },
        .rear = .{ .shield = 1.0, .armor = 0.5 },
        .left = .{ .shield = 1.0, .armor = 0.0 },
        .right = .{ .shield = 1.0, .armor = 1.0 },
    };

    display.render(&fb, &status);

    // Front armor (inner top, inset from shield bar): critical red (32)
    // Inner area starts at y=4 (bar_w=3, +1 gap), armor is 2px tall
    try std.testing.expectEqual(@as(u8, 32), fb.getPixel(15, 4)); // front armor critical

    // Rear armor (inner bottom): moderate yellow (43)
    try std.testing.expectEqual(@as(u8, 43), fb.getPixel(15, 31)); // rear armor moderate

    // Left armor (inner left): empty (2)
    try std.testing.expectEqual(@as(u8, 2), fb.getPixel(4, 18)); // left armor empty

    // Right armor (inner right): full green (47)
    try std.testing.expectEqual(@as(u8, 47), fb.getPixel(43, 18)); // right armor full
}

test "parseDamageConfig extracts values from DAMG chunk" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_mfd.bin");
    defer allocator.free(data);

    var root = try iff.parseFile(allocator, data);
    defer root.deinit();

    const damg_form = root.findForm("DAMG".*) orelse {
        return error.TestUnexpectedResult;
    };

    const config = parseDamageConfig(damg_form) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqual(@as(u16, 100), config.max_value);
    try std.testing.expectEqual(@as(u16, 2), config.num_layers);
}

test "parseDamageDisplay extracts display from cockpit IFF" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_mfd.bin");
    defer allocator.free(data);

    var root = try iff.parseFile(allocator, data);
    defer root.deinit();

    const display = parseDamageDisplay(root) orelse {
        return error.TestUnexpectedResult;
    };

    // Shield rect from fixture: (170, 126, 218, 162)
    try std.testing.expectEqual(@as(u16, 170), display.rect.x1);
    try std.testing.expectEqual(@as(u16, 126), display.rect.y1);
    try std.testing.expectEqual(@as(u16, 218), display.rect.x2);
    try std.testing.expectEqual(@as(u16, 162), display.rect.y2);

    // DAMG config
    try std.testing.expectEqual(@as(u16, 100), display.config.max_value);
    try std.testing.expectEqual(@as(u16, 2), display.config.num_layers);
}

test "shieldColor returns correct color for each damage level" {
    const display = DamageDisplay.init(Rect{ .x1 = 0, .y1 = 0, .x2 = 48, .y2 = 36 });

    // Full = green (47)
    try std.testing.expectEqual(@as(u8, 47), display.shieldColor(1.0));
    try std.testing.expectEqual(@as(u8, 47), display.shieldColor(0.8));

    // Moderate = yellow (43)
    try std.testing.expectEqual(@as(u8, 43), display.shieldColor(0.5));

    // Critical = red (32)
    try std.testing.expectEqual(@as(u8, 32), display.shieldColor(0.2));

    // Empty = dark (2)
    try std.testing.expectEqual(@as(u8, 2), display.shieldColor(0.0));
}

test "drawLine renders pixels between two points" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(0);

    drawLine(&fb, 10, 10, 14, 10, 7);

    // Horizontal line
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(10, 10));
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(12, 10));
    try std.testing.expectEqual(@as(u8, 7), fb.getPixel(14, 10));
    // Above and below untouched
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(12, 9));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(12, 11));
}
