//! Nav map display for Wing Commander: Privateer.
//! Renders the sector map showing star systems, jump connections,
//! player position, and supports system selection for autopilot.
//!
//! Uses Universe (QUADRANT.IFF) and NavGraph (TABLE.DAT) data to render
//! the map procedurally rather than parsing NMAP form data directly.

const std = @import("std");
const framebuffer_mod = @import("framebuffer.zig");
const universe_mod = @import("universe.zig");
const nav_graph_mod = @import("nav_graph.zig");

/// Screen area for the nav map (within 320x200 framebuffer).
pub const MAP_LEFT: u16 = 16;
pub const MAP_TOP: u16 = 16;
pub const MAP_RIGHT: u16 = 303;
pub const MAP_BOTTOM: u16 = 183;
pub const MAP_WIDTH: u16 = MAP_RIGHT - MAP_LEFT;
pub const MAP_HEIGHT: u16 = MAP_BOTTOM - MAP_TOP;

/// Squared distance threshold for hit detection (pixels).
pub const HIT_RADIUS_SQ: i32 = 64;

/// Radius (in pixels) for system dot rendering.
pub const DOT_RADIUS: u16 = 2;

/// Palette color indices for nav map elements.
pub const Color = struct {
    pub const system: u8 = 15;
    pub const connection: u8 = 8;
    pub const selected: u8 = 10;
    pub const player: u8 = 12;
    pub const has_base: u8 = 14;
    pub const border: u8 = 4;
};

/// Screen position in the 320x200 framebuffer.
pub const ScreenPos = struct {
    x: u16,
    y: u16,
};

/// Bounding box for universe-to-screen coordinate mapping.
pub const Bounds = struct {
    min_x: i16,
    min_y: i16,
    max_x: i16,
    max_y: i16,
};

/// Nav map state.
pub const NavMap = struct {
    /// Selected system index (autopilot destination), or null.
    selected_system: ?u8,
    /// Player's current system index.
    player_system: u8,

    pub fn init(player_system: u8) NavMap {
        return .{
            .selected_system = null,
            .player_system = player_system,
        };
    }

    /// Set or clear the autopilot destination.
    pub fn selectSystem(self: *NavMap, system_index: ?u8) void {
        self.selected_system = system_index;
    }

    /// Render the complete nav map onto the framebuffer.
    pub fn render(
        self: NavMap,
        fb: *framebuffer_mod.Framebuffer,
        uni: universe_mod.Universe,
        nav: nav_graph_mod.NavGraph,
    ) void {
        const bounds = computeBounds(uni) orelse return;

        drawRect(fb, MAP_LEFT -| 1, MAP_TOP -| 1, MAP_WIDTH + 2, MAP_HEIGHT + 2, Color.border);
        renderConnections(fb, uni, nav, bounds);
        renderSystems(fb, uni, bounds, self.player_system, self.selected_system);
    }

    /// Find the nearest system to a screen position within hit radius.
    /// Returns the system index, or null if no system is near enough.
    pub fn hitTest(uni: universe_mod.Universe, screen_x: u16, screen_y: u16) ?u8 {
        const bounds = computeBounds(uni) orelse return null;

        var best_dist_sq: i32 = HIT_RADIUS_SQ + 1;
        var best_index: ?u8 = null;

        for (uni.quadrants) |q| {
            for (q.systems) |sys| {
                const pos = mapToScreen(bounds, sys.x, sys.y);
                const dx: i32 = @as(i32, screen_x) - @as(i32, pos.x);
                const dy: i32 = @as(i32, screen_y) - @as(i32, pos.y);
                const dist_sq = dx * dx + dy * dy;
                if (dist_sq < best_dist_sq) {
                    best_dist_sq = dist_sq;
                    best_index = sys.index;
                }
            }
        }

        return best_index;
    }
};

/// Compute the bounding box of all systems in the universe with margin.
pub fn computeBounds(uni: universe_mod.Universe) ?Bounds {
    var min_x: i16 = std.math.maxInt(i16);
    var max_x: i16 = std.math.minInt(i16);
    var min_y: i16 = std.math.maxInt(i16);
    var max_y: i16 = std.math.minInt(i16);
    var count: usize = 0;

    for (uni.quadrants) |q| {
        for (q.systems) |sys| {
            min_x = @min(min_x, sys.x);
            max_x = @max(max_x, sys.x);
            min_y = @min(min_y, sys.y);
            max_y = @max(max_y, sys.y);
            count += 1;
        }
    }

    if (count == 0) return null;

    const range_x: i32 = @as(i32, max_x) - @as(i32, min_x);
    const range_y: i32 = @as(i32, max_y) - @as(i32, min_y);
    const margin_x: i16 = @intCast(@max(@as(i32, 10), @divTrunc(range_x, 10)));
    const margin_y: i16 = @intCast(@max(@as(i32, 10), @divTrunc(range_y, 10)));

    return Bounds{
        .min_x = @intCast(std.math.clamp(@as(i32, min_x) - @as(i32, margin_x), std.math.minInt(i16), std.math.maxInt(i16))),
        .min_y = @intCast(std.math.clamp(@as(i32, min_y) - @as(i32, margin_y), std.math.minInt(i16), std.math.maxInt(i16))),
        .max_x = @intCast(std.math.clamp(@as(i32, max_x) + @as(i32, margin_x), std.math.minInt(i16), std.math.maxInt(i16))),
        .max_y = @intCast(std.math.clamp(@as(i32, max_y) + @as(i32, margin_y), std.math.minInt(i16), std.math.maxInt(i16))),
    };
}

/// Map universe coordinates to screen position within the map area.
/// Y is inverted: higher universe Y maps to lower screen Y (top of screen).
pub fn mapToScreen(bounds: Bounds, sys_x: i16, sys_y: i16) ScreenPos {
    const range_x: i32 = @as(i32, bounds.max_x) - @as(i32, bounds.min_x);
    const range_y: i32 = @as(i32, bounds.max_y) - @as(i32, bounds.min_y);

    if (range_x <= 0 or range_y <= 0) {
        return .{ .x = MAP_LEFT + MAP_WIDTH / 2, .y = MAP_TOP + MAP_HEIGHT / 2 };
    }

    const norm_x: i32 = @as(i32, sys_x) - @as(i32, bounds.min_x);
    const norm_y: i32 = @as(i32, bounds.max_y) - @as(i32, sys_y);

    const sx = std.math.clamp(@divTrunc(norm_x * @as(i32, MAP_WIDTH), range_x), 0, @as(i32, MAP_WIDTH));
    const sy = std.math.clamp(@divTrunc(norm_y * @as(i32, MAP_HEIGHT), range_y), 0, @as(i32, MAP_HEIGHT));

    return .{
        .x = MAP_LEFT + @as(u16, @intCast(sx)),
        .y = MAP_TOP + @as(u16, @intCast(sy)),
    };
}

/// Determine the color for a system dot based on game state.
fn systemColor(sys: universe_mod.StarSystem, player_system: u8, selected_system: ?u8) u8 {
    if (sys.index == player_system) return Color.player;
    if (selected_system) |sel| {
        if (sys.index == sel) return Color.selected;
    }
    return if (sys.hasBase()) Color.has_base else Color.system;
}

/// Draw jump connections between adjacent systems.
fn renderConnections(
    fb: *framebuffer_mod.Framebuffer,
    uni: universe_mod.Universe,
    nav: nav_graph_mod.NavGraph,
    bounds: Bounds,
) void {
    const n: u16 = @min(nav.system_count, 256);
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        var j: u16 = i + 1;
        while (j < n) : (j += 1) {
            if (nav.isAdjacent(@intCast(i), @intCast(j))) {
                const sys_a = uni.findSystemByIndex(@intCast(i)) orelse continue;
                const sys_b = uni.findSystemByIndex(@intCast(j)) orelse continue;
                const pos_a = mapToScreen(bounds, sys_a.x, sys_a.y);
                const pos_b = mapToScreen(bounds, sys_b.x, sys_b.y);
                drawLine(fb, pos_a.x, pos_a.y, pos_b.x, pos_b.y, Color.connection);
            }
        }
    }
}

/// Draw system dots with appropriate colors.
fn renderSystems(
    fb: *framebuffer_mod.Framebuffer,
    uni: universe_mod.Universe,
    bounds: Bounds,
    player_system: u8,
    selected_system: ?u8,
) void {
    for (uni.quadrants) |q| {
        for (q.systems) |sys| {
            const pos = mapToScreen(bounds, sys.x, sys.y);
            const color = systemColor(sys, player_system, selected_system);
            drawDot(fb, pos.x, pos.y, DOT_RADIUS, color);
        }
    }
}

/// Draw a filled circle (dot) on the framebuffer.
pub fn drawDot(fb: *framebuffer_mod.Framebuffer, cx: u16, cy: u16, radius: u16, color: u8) void {
    const r: i32 = @intCast(radius);
    const r_sq = r * r;
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            if (dx * dx + dy * dy <= r_sq) {
                const px = @as(i32, cx) + dx;
                const py = @as(i32, cy) + dy;
                if (px >= 0 and py >= 0) {
                    fb.setPixel(@intCast(px), @intCast(py), color);
                }
            }
        }
    }
}

/// Draw a line using Bresenham's algorithm.
pub fn drawLine(fb: *framebuffer_mod.Framebuffer, x0: u16, y0: u16, x1: u16, y1: u16, color: u8) void {
    var x: i32 = @intCast(x0);
    var y: i32 = @intCast(y0);
    const ex: i32 = @intCast(x1);
    const ey: i32 = @intCast(y1);

    const dx: i32 = if (ex >= x) ex - x else x - ex;
    const dy: i32 = -(if (ey >= y) ey - y else y - ey);
    const sx: i32 = if (x < ex) 1 else -1;
    const sy: i32 = if (y < ey) 1 else -1;
    var err: i32 = dx + dy;

    while (true) {
        if (x >= 0 and y >= 0) {
            fb.setPixel(@intCast(x), @intCast(y), color);
        }
        if (x == ex and y == ey) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

/// Draw a rectangle outline on the framebuffer.
pub fn drawRect(fb: *framebuffer_mod.Framebuffer, x: u16, y: u16, w: u16, h: u16, color: u8) void {
    var i: u16 = 0;
    while (i < w) : (i += 1) {
        fb.setPixel(x +| i, y, color);
        fb.setPixel(x +| i, y +| (h -| 1), color);
    }
    i = 0;
    while (i < h) : (i += 1) {
        fb.setPixel(x, y +| i, color);
        fb.setPixel(x +| (w -| 1), y +| i, color);
    }
}

// --- Tests ---

const testing_helpers = @import("testing.zig");

fn loadTestUniverse(allocator: std.mem.Allocator) !universe_mod.Universe {
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);
    return universe_mod.parseUniverse(allocator, data);
}

fn loadTestNavGraph(allocator: std.mem.Allocator) !nav_graph_mod.NavGraph {
    const data = try testing_helpers.loadFixture(allocator, "test_table.bin");
    defer allocator.free(data);
    return nav_graph_mod.parseNavGraph(allocator, data);
}

test "NavMap init has correct defaults" {
    const nm = NavMap.init(0);
    try std.testing.expectEqual(@as(u8, 0), nm.player_system);
    try std.testing.expect(nm.selected_system == null);
}

test "NavMap selectSystem sets and clears destination" {
    var nm = NavMap.init(0);
    nm.selectSystem(5);
    try std.testing.expectEqual(@as(u8, 5), nm.selected_system.?);
    nm.selectSystem(null);
    try std.testing.expect(nm.selected_system == null);
}

test "computeBounds returns valid bounds containing all systems" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();

    const bounds = computeBounds(uni).?;
    // Bounds must have positive range
    try std.testing.expect(bounds.min_x < bounds.max_x);
    try std.testing.expect(bounds.min_y < bounds.max_y);
    // Every system must be within bounds
    for (uni.quadrants) |q| {
        for (q.systems) |sys| {
            try std.testing.expect(sys.x >= bounds.min_x);
            try std.testing.expect(sys.x <= bounds.max_x);
            try std.testing.expect(sys.y >= bounds.min_y);
            try std.testing.expect(sys.y <= bounds.max_y);
        }
    }
}

test "mapToScreen maps systems to valid screen positions" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();

    const bounds = computeBounds(uni).?;
    for (uni.quadrants) |q| {
        for (q.systems) |sys| {
            const pos = mapToScreen(bounds, sys.x, sys.y);
            try std.testing.expect(pos.x >= MAP_LEFT);
            try std.testing.expect(pos.x <= MAP_RIGHT);
            try std.testing.expect(pos.y >= MAP_TOP);
            try std.testing.expect(pos.y <= MAP_BOTTOM);
        }
    }
}

test "mapToScreen produces distinct positions for different systems" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();

    const bounds = computeBounds(uni).?;
    var positions: [5]ScreenPos = undefined;
    var idx: usize = 0;
    for (uni.quadrants) |q| {
        for (q.systems) |sys| {
            positions[idx] = mapToScreen(bounds, sys.x, sys.y);
            idx += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), idx);

    for (0..idx) |i| {
        for (i + 1..idx) |j| {
            const same = positions[i].x == positions[j].x and positions[i].y == positions[j].y;
            try std.testing.expect(!same);
        }
    }
}

test "drawLine draws horizontal line" {
    var fb = framebuffer_mod.Framebuffer.create();
    drawLine(&fb, 10, 50, 20, 50, 5);

    var i: u16 = 10;
    while (i <= 20) : (i += 1) {
        try std.testing.expectEqual(@as(u8, 5), fb.getPixel(i, 50));
    }
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(9, 50));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(21, 50));
}

test "drawLine draws vertical line" {
    var fb = framebuffer_mod.Framebuffer.create();
    drawLine(&fb, 50, 10, 50, 20, 7);

    var i: u16 = 10;
    while (i <= 20) : (i += 1) {
        try std.testing.expectEqual(@as(u8, 7), fb.getPixel(50, i));
    }
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(50, 9));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(50, 21));
}

test "drawLine draws single point" {
    var fb = framebuffer_mod.Framebuffer.create();
    drawLine(&fb, 100, 100, 100, 100, 3);
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(100, 100));
}

test "drawDot draws filled circle" {
    var fb = framebuffer_mod.Framebuffer.create();
    drawDot(&fb, 50, 50, 2, 9);

    // Center
    try std.testing.expectEqual(@as(u8, 9), fb.getPixel(50, 50));
    // Cardinal at distance 1 and 2
    try std.testing.expectEqual(@as(u8, 9), fb.getPixel(51, 50));
    try std.testing.expectEqual(@as(u8, 9), fb.getPixel(52, 50));
    try std.testing.expectEqual(@as(u8, 9), fb.getPixel(50, 52));
    // Diagonal (2,2) outside radius 2 circle (4+4=8 > 4)
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(52, 52));
    // Outside radius
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(53, 50));
}

test "drawRect draws rectangle outline" {
    var fb = framebuffer_mod.Framebuffer.create();
    drawRect(&fb, 10, 10, 5, 5, 3);

    // Corners
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(10, 10));
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(14, 10));
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(10, 14));
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(14, 14));
    // Edges
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(10, 12));
    try std.testing.expectEqual(@as(u8, 3), fb.getPixel(14, 12));
    // Interior empty
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(12, 12));
}

test "render produces non-black framebuffer" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();
    var nav = try loadTestNavGraph(allocator);
    defer nav.deinit();

    var fb = framebuffer_mod.Framebuffer.create();
    const nm = NavMap.init(0);
    nm.render(&fb, uni, nav);

    var non_zero: usize = 0;
    for (fb.pixels) |p| {
        if (p != 0) non_zero += 1;
    }
    try std.testing.expect(non_zero > 0);
}

test "render draws player system in player color" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();
    var nav = try loadTestNavGraph(allocator);
    defer nav.deinit();

    var fb = framebuffer_mod.Framebuffer.create();
    const nm = NavMap.init(0);
    nm.render(&fb, uni, nav);

    const bounds = computeBounds(uni).?;
    const troy = uni.findSystemByIndex(0).?;
    const pos = mapToScreen(bounds, troy.x, troy.y);
    try std.testing.expectEqual(Color.player, fb.getPixel(pos.x, pos.y));
}

test "render draws selected system in selected color" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();
    var nav = try loadTestNavGraph(allocator);
    defer nav.deinit();

    var fb = framebuffer_mod.Framebuffer.create();
    var nm = NavMap.init(0);
    nm.selectSystem(3);
    nm.render(&fb, uni, nav);

    const bounds = computeBounds(uni).?;
    const perry = uni.findSystemByIndex(3).?;
    const pos = mapToScreen(bounds, perry.x, perry.y);
    try std.testing.expectEqual(Color.selected, fb.getPixel(pos.x, pos.y));
}

test "hitTest finds system at its screen position" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();

    const bounds = computeBounds(uni).?;
    const troy = uni.findSystemByIndex(0).?;
    const pos = mapToScreen(bounds, troy.x, troy.y);

    const result = NavMap.hitTest(uni, pos.x, pos.y);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, 0), result.?);
}

test "hitTest returns null far from any system" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();

    const result = NavMap.hitTest(uni, 0, 0);
    try std.testing.expect(result == null);
}

test "hitTest click sets autopilot destination" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();

    var nm = NavMap.init(0);
    const bounds = computeBounds(uni).?;
    const perry = uni.findSystemByIndex(3).?;
    const pos = mapToScreen(bounds, perry.x, perry.y);

    if (NavMap.hitTest(uni, pos.x, pos.y)) |sys_idx| {
        nm.selectSystem(sys_idx);
    }
    try std.testing.expectEqual(@as(u8, 3), nm.selected_system.?);
}

test "systemColor prioritizes player over selected" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();

    const troy = uni.findSystemByIndex(0).?;
    // Player at system 0, also selected as destination
    try std.testing.expectEqual(Color.player, systemColor(troy.*, 0, 0));
}

test "systemColor shows has_base for systems with bases" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();

    const troy = uni.findSystemByIndex(0).?;
    // Troy has bases, player elsewhere, not selected
    try std.testing.expectEqual(Color.has_base, systemColor(troy.*, 99, null));
}

test "systemColor shows normal for baseless systems" {
    const allocator = std.testing.allocator;
    var uni = try loadTestUniverse(allocator);
    defer uni.deinit();

    const palan = uni.findSystemByIndex(1).?;
    // Palan has no bases
    try std.testing.expectEqual(Color.system, systemColor(palan.*, 99, null));
}
