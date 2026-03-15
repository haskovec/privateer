//! Click region / interaction system for Wing Commander: Privateer.
//! Handles hit-testing of clickable areas on landing screens and
//! parsing sprite EFCT data into actions (scene transitions, merchant, etc.).
//!
//! Each scene sprite has:
//!   - A bounding rectangle (from the PAK sprite image bounds)
//!   - An action (from the EFCT chunk in GAMEFLOW.IFF)
//!
//! EFCT format (2 bytes, most common):
//!   byte[0] = action type
//!   byte[1] = parameter (e.g., target scene ID)
//!
//! Action types:
//!   0x00 = no action (decorative sprite)
//!   0x01 = scene transition (param = target scene ID)
//!   0x0E = launch/takeoff sequence
//!   0x18 = takeoff (initiate launch from base)
//!   0x19 = conversation (bar patrons)
//!   0x1A = conversation (bartender/fixer)
//!   0x1B = ship dealer
//!   0x1C = commodity exchange
//!   0x1E = equipment/upgrade dealer
//!
//! Longer EFCT data (>2 bytes) represents scripted sequences.

const std = @import("std");

/// Action to perform when a click region is activated.
pub const Action = union(enum) {
    /// No action (decorative sprite).
    none,
    /// Navigate to a different scene.
    scene_transition: u8,
    /// Launch/takeoff from base (0x0E).
    launch,
    /// Initiate takeoff sequence (0x18).
    takeoff,
    /// Open conversation with bar patron (0x19, param = sub-type).
    bar_conversation: u8,
    /// Open conversation with bartender/fixer (0x1A, param = sub-type).
    bartender_conversation: u8,
    /// Open ship dealer interface (0x1B).
    ship_dealer,
    /// Open commodity exchange (0x1C).
    commodity_exchange,
    /// Open equipment/upgrade dealer (0x1E, param = sub-type).
    equipment_dealer: u8,
    /// Open mission computer (0x1D).
    mission_computer,
    /// Complex scripted sequence (raw EFCT data > 2 bytes).
    scripted: []const u8,
};

/// Parse EFCT data into an Action.
pub fn parseAction(efct: []const u8) Action {
    if (efct.len == 0) return .none;

    // Long EFCT data = scripted sequence
    if (efct.len > 2) return .{ .scripted = efct };

    const action_type = efct[0];
    const param: u8 = if (efct.len >= 2) efct[1] else 0;

    return switch (action_type) {
        0x00 => .none,
        0x01 => .{ .scene_transition = param },
        0x0E => .launch,
        0x18 => .takeoff,
        0x19 => .{ .bar_conversation = param },
        0x1A => .{ .bartender_conversation = param },
        0x1B => .ship_dealer,
        0x1C => .commodity_exchange,
        0x1D => .mission_computer,
        0x1E => .{ .equipment_dealer = param },
        else => .none,
    };
}

/// A rectangular clickable region on a scene.
pub const ClickRegion = struct {
    /// Left edge in screen coordinates (320x200 space).
    x: i16,
    /// Top edge in screen coordinates.
    y: i16,
    /// Width in pixels.
    width: u16,
    /// Height in pixels.
    height: u16,
    /// Sprite identifier (from GAMEFLOW SPRT INFO byte).
    sprite_id: u8,
    /// Action to perform when clicked.
    action: Action,

    /// Test if a point is inside this region.
    pub fn containsPoint(self: ClickRegion, px: i16, py: i16) bool {
        return px >= self.x and
            px < self.x + @as(i16, @intCast(self.width)) and
            py >= self.y and
            py < self.y + @as(i16, @intCast(self.height));
    }
};

/// Result of a hit test.
pub const HitResult = struct {
    /// The matched region.
    region: *const ClickRegion,
    /// Index of the region in the array.
    index: usize,
};

/// Test which click region (if any) contains the given point.
/// Returns the last (topmost) matching region, since sprites are rendered
/// in order and later sprites are on top.
pub fn hitTest(regions: []const ClickRegion, px: i16, py: i16) ?HitResult {
    var result: ?HitResult = null;
    for (regions, 0..) |*region, i| {
        if (region.containsPoint(px, py)) {
            result = .{ .region = region, .index = i };
        }
    }
    return result;
}

// --- Tests ---

test "parseAction returns none for empty EFCT" {
    const action = parseAction(&.{});
    try std.testing.expect(action == .none);
}

test "parseAction returns none for action type 0x00" {
    const action = parseAction(&.{ 0x00, 0x00 });
    try std.testing.expect(action == .none);
}

test "parseAction returns scene_transition for action type 0x01" {
    const action = parseAction(&.{ 0x01, 0x0E });
    try std.testing.expect(action == .scene_transition);
    try std.testing.expectEqual(@as(u8, 0x0E), action.scene_transition);
}

test "parseAction returns launch for action type 0x0E" {
    const action = parseAction(&.{ 0x0E, 0x00 });
    try std.testing.expect(action == .launch);
}

test "parseAction returns takeoff for action type 0x18" {
    const action = parseAction(&.{ 0x18, 0x00 });
    try std.testing.expect(action == .takeoff);
}

test "parseAction returns bar_conversation for action type 0x19" {
    const action = parseAction(&.{ 0x19, 0x01 });
    try std.testing.expect(action == .bar_conversation);
    try std.testing.expectEqual(@as(u8, 0x01), action.bar_conversation);
}

test "parseAction returns bartender_conversation for action type 0x1A" {
    const action = parseAction(&.{ 0x1A, 0x00 });
    try std.testing.expect(action == .bartender_conversation);
    try std.testing.expectEqual(@as(u8, 0x00), action.bartender_conversation);
}

test "parseAction returns ship_dealer for action type 0x1B" {
    const action = parseAction(&.{ 0x1B, 0x00 });
    try std.testing.expect(action == .ship_dealer);
}

test "parseAction returns commodity_exchange for action type 0x1C" {
    const action = parseAction(&.{ 0x1C, 0x00 });
    try std.testing.expect(action == .commodity_exchange);
}

test "parseAction returns mission_computer for action type 0x1D" {
    const action = parseAction(&.{ 0x1D, 0x00 });
    try std.testing.expect(action == .mission_computer);
}

test "parseAction returns equipment_dealer for action type 0x1E" {
    const action = parseAction(&.{ 0x1E, 0x02 });
    try std.testing.expect(action == .equipment_dealer);
    try std.testing.expectEqual(@as(u8, 0x02), action.equipment_dealer);
}

test "parseAction returns scripted for long EFCT data" {
    const data = [_]u8{ 0x06, 0x05, 0x21, 0x14, 0x23, 0x00 };
    const action = parseAction(&data);
    try std.testing.expect(action == .scripted);
    try std.testing.expectEqual(@as(usize, 6), action.scripted.len);
}

test "parseAction handles single-byte EFCT" {
    const action = parseAction(&.{0x0E});
    try std.testing.expect(action == .launch);
}

test "ClickRegion.containsPoint returns true for point inside" {
    const region = ClickRegion{
        .x = 10,
        .y = 20,
        .width = 50,
        .height = 30,
        .sprite_id = 0,
        .action = .none,
    };
    try std.testing.expect(region.containsPoint(10, 20));
    try std.testing.expect(region.containsPoint(35, 35));
    try std.testing.expect(region.containsPoint(59, 49));
}

test "ClickRegion.containsPoint returns false for point outside" {
    const region = ClickRegion{
        .x = 10,
        .y = 20,
        .width = 50,
        .height = 30,
        .sprite_id = 0,
        .action = .none,
    };
    try std.testing.expect(!region.containsPoint(9, 20));
    try std.testing.expect(!region.containsPoint(10, 19));
    try std.testing.expect(!region.containsPoint(60, 35));
    try std.testing.expect(!region.containsPoint(35, 50));
}

test "ClickRegion.containsPoint handles zero-size region" {
    const region = ClickRegion{
        .x = 10,
        .y = 20,
        .width = 0,
        .height = 0,
        .sprite_id = 0,
        .action = .none,
    };
    try std.testing.expect(!region.containsPoint(10, 20));
}

test "hitTest returns null for no regions" {
    const regions: []const ClickRegion = &.{};
    try std.testing.expect(hitTest(regions, 10, 10) == null);
}

test "hitTest returns null for point outside all regions" {
    const regions = [_]ClickRegion{
        .{ .x = 10, .y = 10, .width = 20, .height = 20, .sprite_id = 1, .action = .none },
        .{ .x = 50, .y = 50, .width = 20, .height = 20, .sprite_id = 2, .action = .none },
    };
    try std.testing.expect(hitTest(&regions, 0, 0) == null);
    try std.testing.expect(hitTest(&regions, 35, 35) == null);
}

test "hitTest returns matching region" {
    const regions = [_]ClickRegion{
        .{ .x = 10, .y = 10, .width = 20, .height = 20, .sprite_id = 1, .action = .{ .scene_transition = 0x0E } },
        .{ .x = 50, .y = 50, .width = 20, .height = 20, .sprite_id = 2, .action = .{ .scene_transition = 0x0F } },
    };

    const result1 = hitTest(&regions, 15, 15);
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(u8, 1), result1.?.region.sprite_id);
    try std.testing.expectEqual(@as(usize, 0), result1.?.index);

    const result2 = hitTest(&regions, 55, 55);
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(u8, 2), result2.?.region.sprite_id);
    try std.testing.expectEqual(@as(usize, 1), result2.?.index);
}

test "hitTest returns topmost (last) region for overlapping regions" {
    const regions = [_]ClickRegion{
        .{ .x = 0, .y = 0, .width = 100, .height = 100, .sprite_id = 1, .action = .none },
        .{ .x = 20, .y = 20, .width = 30, .height = 30, .sprite_id = 2, .action = .{ .scene_transition = 0x0E } },
    };

    // Point in overlap area returns the topmost (last) region
    const result = hitTest(&regions, 25, 25);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 2), result.?.region.sprite_id);
    try std.testing.expectEqual(@as(usize, 1), result.?.index);

    // Point only in first region
    const result2 = hitTest(&regions, 5, 5);
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(u8, 1), result2.?.region.sprite_id);
}

test "hitTest with scene_transition action returns correct target" {
    const regions = [_]ClickRegion{
        .{ .x = 0, .y = 0, .width = 160, .height = 200, .sprite_id = 0xCE, .action = .{ .scene_transition = 0x0E } },
        .{ .x = 160, .y = 0, .width = 160, .height = 200, .sprite_id = 0xCF, .action = .{ .scene_transition = 0x0F } },
    };

    const result = hitTest(&regions, 80, 100);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 0x0E), result.?.region.action.scene_transition);

    const result2 = hitTest(&regions, 240, 100);
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(u8, 0x0F), result2.?.region.action.scene_transition);
}
