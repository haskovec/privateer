//! Radar display for Wing Commander: Privateer.
//!
//! Renders a top-down radar showing nearby contacts colored by faction.
//! The player is always at the center, with the player's forward direction
//! pointing up on the display. Contacts beyond the radar range are clipped.

const std = @import("std");
const mfd = @import("mfd.zig");
const framebuffer_mod = @import("../render/framebuffer.zig");
const flight_physics = @import("../flight/flight_physics.zig");

const Vec3 = flight_physics.Vec3;
const Rect = mfd.Rect;

/// Faction affiliation for radar contacts.
pub const Faction = enum {
    friendly,
    neutral,
    hostile,
};

/// A single radar contact (ship or object in space).
pub const RadarContact = struct {
    /// World-space position.
    position: Vec3,
    /// Faction for IFF coloring.
    faction: Faction,
};

/// Palette color indices for radar display elements.
pub const RadarColors = struct {
    background: u8 = 0,
    friendly: u8 = 47,
    neutral: u8 = 43,
    hostile: u8 = 32,
    player: u8 = 15,
};

/// Radar display state and renderer.
pub const Radar = struct {
    /// Screen rectangle (from DIAL RADR INFO).
    rect: Rect,
    /// Maximum detection range in world units.
    range: f32,
    /// Palette color indices.
    colors: RadarColors,

    /// Create a radar with the given display rect and range.
    pub fn init(rect: Rect, range: f32) Radar {
        return .{
            .rect = rect,
            .range = range,
            .colors = .{},
        };
    }

    /// Render the radar display onto the framebuffer.
    /// Shows the player at center and all in-range contacts as colored blips.
    pub fn render(
        self: *const Radar,
        fb: *framebuffer_mod.Framebuffer,
        player: *const flight_physics.FlightState,
        contacts: []const RadarContact,
    ) void {
        const w = self.rect.width();
        const h = self.rect.height();
        if (w == 0 or h == 0) return;
        if (self.range <= 0) return;

        // Fill background
        mfd.fillRect(fb, self.rect, self.colors.background);

        // Radar center in screen coordinates
        const half_w: f32 = @as(f32, @floatFromInt(w)) / 2.0;
        const half_h: f32 = @as(f32, @floatFromInt(h)) / 2.0;
        const cx: f32 = @as(f32, @floatFromInt(self.rect.x1)) + half_w;
        const cy: f32 = @as(f32, @floatFromInt(self.rect.y1)) + half_h;

        // Draw player dot at center
        const cx_u16: u16 = @intFromFloat(cx);
        const cy_u16: u16 = @intFromFloat(cy);
        fb.setPixel(cx_u16, cy_u16, self.colors.player);

        // Precompute yaw rotation
        const sin_yaw = @sin(player.yaw);
        const cos_yaw = @cos(player.yaw);

        // Bounds for clipping
        const x1_f: f32 = @floatFromInt(self.rect.x1);
        const x2_f: f32 = @floatFromInt(self.rect.x2);
        const y1_f: f32 = @floatFromInt(self.rect.y1);
        const y2_f: f32 = @floatFromInt(self.rect.y2);

        const range_sq = self.range * self.range;

        for (contacts) |contact| {
            // Relative position in world space
            const dx = contact.position.x - player.position.x;
            const dz = contact.position.z - player.position.z;

            // Range check (horizontal X/Z plane)
            if (dx * dx + dz * dz > range_sq) continue;

            // Rotate by negative player yaw so forward maps to up on screen.
            // After rotation: rx = right offset, rz = forward offset.
            const rx = dx * cos_yaw - dz * sin_yaw;
            const rz = dx * sin_yaw + dz * cos_yaw;

            // Map to screen pixel coordinates.
            const px = cx + (rx / self.range) * half_w;
            const py = cy - (rz / self.range) * half_h;

            // Clip to radar rect bounds
            if (px < x1_f or px >= x2_f) continue;
            if (py < y1_f or py >= y2_f) continue;

            const color = switch (contact.faction) {
                .friendly => self.colors.friendly,
                .neutral => self.colors.neutral,
                .hostile => self.colors.hostile,
            };

            fb.setPixel(@intFromFloat(px), @intFromFloat(py), color);
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "radar renders player center dot" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(99); // non-zero to detect background fill

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 20, .y2 = 20 };
    const radar = Radar.init(rect, 100.0);
    const player = flight_physics.FlightState.init(flight_physics.ship_stats.tarsus);

    radar.render(&fb, &player, &[_]RadarContact{});

    // Center pixel should have player color
    try std.testing.expectEqual(@as(u8, 15), fb.getPixel(10, 10));
    // Background should be filled with radar bg color (0)
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(19, 19));
    // Outside radar rect should be untouched
    try std.testing.expectEqual(@as(u8, 99), fb.getPixel(20, 20));
}

test "radar shows friendly contact as green" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 20, .y2 = 20 };
    const radar = Radar.init(rect, 100.0);
    var player = flight_physics.FlightState.init(flight_physics.ship_stats.tarsus);
    player.position = Vec3.zero;

    // Contact directly ahead at half range
    const contacts = [_]RadarContact{
        .{ .position = Vec3{ .x = 0, .y = 0, .z = 50 }, .faction = .friendly },
    };

    radar.render(&fb, &player, &contacts);

    // Ahead = up on radar. Half range → halfway between center and top.
    // center=(10,10), half_h=10, rz=50, range=100
    // py = 10 - (50/100)*10 = 5
    try std.testing.expectEqual(@as(u8, 47), fb.getPixel(10, 5));
}

test "radar shows hostile contact as red" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 20, .y2 = 20 };
    const radar = Radar.init(rect, 100.0);
    var player = flight_physics.FlightState.init(flight_physics.ship_stats.tarsus);
    player.position = Vec3.zero;

    const contacts = [_]RadarContact{
        .{ .position = Vec3{ .x = 0, .y = 0, .z = 50 }, .faction = .hostile },
    };

    radar.render(&fb, &player, &contacts);

    try std.testing.expectEqual(@as(u8, 32), fb.getPixel(10, 5));
}

test "radar shows neutral contact as yellow" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 20, .y2 = 20 };
    const radar = Radar.init(rect, 100.0);
    var player = flight_physics.FlightState.init(flight_physics.ship_stats.tarsus);
    player.position = Vec3.zero;

    const contacts = [_]RadarContact{
        .{ .position = Vec3{ .x = 0, .y = 0, .z = 50 }, .faction = .neutral },
    };

    radar.render(&fb, &player, &contacts);

    try std.testing.expectEqual(@as(u8, 43), fb.getPixel(10, 5));
}

test "radar hides contacts outside range" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 20, .y2 = 20 };
    const radar = Radar.init(rect, 100.0);
    var player = flight_physics.FlightState.init(flight_physics.ship_stats.tarsus);
    player.position = Vec3.zero;

    const contacts = [_]RadarContact{
        .{ .position = Vec3{ .x = 0, .y = 0, .z = 200 }, .faction = .hostile },
    };

    radar.render(&fb, &player, &contacts);

    // Only player center dot should be non-background
    var non_bg_count: u32 = 0;
    var y: u16 = 0;
    while (y < 20) : (y += 1) {
        var x: u16 = 0;
        while (x < 20) : (x += 1) {
            if (fb.getPixel(x, y) != 0) non_bg_count += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), non_bg_count);
}

test "radar contact directly behind appears below center" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 20, .y2 = 20 };
    const radar = Radar.init(rect, 100.0);
    var player = flight_physics.FlightState.init(flight_physics.ship_stats.tarsus);
    player.position = Vec3.zero;

    const contacts = [_]RadarContact{
        .{ .position = Vec3{ .x = 0, .y = 0, .z = -50 }, .faction = .hostile },
    };

    radar.render(&fb, &player, &contacts);

    // Behind → below center: py = 10 - (-50/100)*10 = 15
    try std.testing.expectEqual(@as(u8, 32), fb.getPixel(10, 15));
}

test "radar contact to the right appears right of center" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 20, .y2 = 20 };
    const radar = Radar.init(rect, 100.0);
    var player = flight_physics.FlightState.init(flight_physics.ship_stats.tarsus);
    player.position = Vec3.zero;

    const contacts = [_]RadarContact{
        .{ .position = Vec3{ .x = 50, .y = 0, .z = 0 }, .faction = .friendly },
    };

    radar.render(&fb, &player, &contacts);

    // Right: rx=50, rz=0 → px=15, py=10
    try std.testing.expectEqual(@as(u8, 47), fb.getPixel(15, 10));
}

test "radar rotates with player yaw" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 20, .y2 = 20 };
    const radar = Radar.init(rect, 100.0);
    var player = flight_physics.FlightState.init(flight_physics.ship_stats.tarsus);
    player.position = Vec3.zero;
    player.yaw = std.math.pi / 2.0; // facing +X

    // Contact at +X (ahead when facing +X)
    const contacts = [_]RadarContact{
        .{ .position = Vec3{ .x = 50, .y = 0, .z = 0 }, .faction = .hostile },
    };

    radar.render(&fb, &player, &contacts);

    // With yaw=pi/2: cos≈0, sin≈1
    // dx=50, dz=0 → rx=0, rz=50 → px=10, py=5
    // Contact ahead should appear above center
    try std.testing.expectEqual(@as(u8, 32), fb.getPixel(10, 5));
}

test "radar renders multiple contacts simultaneously" {
    var fb = framebuffer_mod.Framebuffer.create();

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 20, .y2 = 20 };
    const radar = Radar.init(rect, 100.0);
    var player = flight_physics.FlightState.init(flight_physics.ship_stats.tarsus);
    player.position = Vec3.zero;

    const contacts = [_]RadarContact{
        .{ .position = Vec3{ .x = 0, .y = 0, .z = 50 }, .faction = .friendly },
        .{ .position = Vec3{ .x = 50, .y = 0, .z = 0 }, .faction = .hostile },
        .{ .position = Vec3{ .x = 0, .y = 0, .z = -50 }, .faction = .neutral },
    };

    radar.render(&fb, &player, &contacts);

    try std.testing.expectEqual(@as(u8, 47), fb.getPixel(10, 5)); // friendly ahead
    try std.testing.expectEqual(@as(u8, 32), fb.getPixel(15, 10)); // hostile right
    try std.testing.expectEqual(@as(u8, 43), fb.getPixel(10, 15)); // neutral behind
    try std.testing.expectEqual(@as(u8, 15), fb.getPixel(10, 10)); // player center
}

test "radar with zero range renders nothing" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(99);

    const rect = Rect{ .x1 = 0, .y1 = 0, .x2 = 20, .y2 = 20 };
    const radar = Radar.init(rect, 0.0);
    const player = flight_physics.FlightState.init(flight_physics.ship_stats.tarsus);

    radar.render(&fb, &player, &[_]RadarContact{});

    // Nothing should change
    try std.testing.expectEqual(@as(u8, 99), fb.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 99), fb.getPixel(10, 10));
}

test "radar with offset rect positions correctly" {
    var fb = framebuffer_mod.Framebuffer.create();

    // Simulate the actual game radar rect position
    const rect = Rect{ .x1 = 90, .y1 = 126, .x2 = 138, .y2 = 162 };
    const radar = Radar.init(rect, 1000.0);
    var player = flight_physics.FlightState.init(flight_physics.ship_stats.tarsus);
    player.position = Vec3.zero;

    radar.render(&fb, &player, &[_]RadarContact{});

    // Center of (90,126)-(138,162) = (114, 144)
    try std.testing.expectEqual(@as(u8, 15), fb.getPixel(114, 144));
    // Background filled inside rect
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(90, 126));
    // Outside rect untouched
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(89, 126));
}
